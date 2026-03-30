package com.example.message_app

import android.Manifest
import android.app.role.RoleManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "pulse/messages"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyHighRefreshPreference()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isDefaultSmsApp" -> result.success(isDefaultSmsApp())
                    "requestDefaultSmsApp" -> requestDefaultSmsApp(result)
                    "fetchConversations" -> result.success(fetchConversations())
                    "sendSms" -> sendSms(call, result)
                    "composeMms" -> composeMms(call, result)
                    "startCall" -> startCall(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun applyHighRefreshPreference() {
        val params = window.attributes
        params.preferredRefreshRate = 120f

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val currentDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            }

            val bestMode = currentDisplay?.supportedModes?.maxByOrNull { it.refreshRate }
            if (bestMode != null) {
                params.preferredDisplayModeId = bestMode.modeId
            }
        }

        window.attributes = params
    }

    private fun isDefaultSmsApp(): Boolean {
        val packageName = packageName
        val defaultPackage = Telephony.Sms.getDefaultSmsPackage(this)
        return packageName == defaultPackage
    }

    private fun requestDefaultSmsApp(result: MethodChannel.Result) {
        if (isDefaultSmsApp()) {
            result.success(true)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = getSystemService(RoleManager::class.java)
            if (roleManager == null || !roleManager.isRoleAvailable(RoleManager.ROLE_SMS)) {
                result.success(false)
                return
            }
            if (roleManager.isRoleHeld(RoleManager.ROLE_SMS)) {
                result.success(true)
                return
            }

            startActivity(roleManager.createRequestRoleIntent(RoleManager.ROLE_SMS))
            result.success(true)
            return
        }

        val intent = Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).apply {
            putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, packageName)
        }
        startActivity(intent)
        result.success(true)
    }

    private fun fetchConversations(): List<Map<String, Any>> {
        val smsPermission = ActivityCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_SMS
        )
        if (smsPermission != PackageManager.PERMISSION_GRANTED) {
            return emptyList()
        }

        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE
        )
        val cursor = contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            projection,
            null,
            null,
            "${Telephony.Sms.DATE} DESC"
        ) ?: return emptyList()

        val firstByAddress = linkedMapOf<String, Map<String, Any>>()
        val contactNameCache = hashMapOf<String, String>()
        cursor.use {
            val idIndex = cursor.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addressIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val typeIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.TYPE)

            while (cursor.moveToNext() && firstByAddress.size < 25) {
                val address = cursor.getString(addressIndex) ?: "Unknown"
                if (firstByAddress.containsKey(address)) continue

                val id = cursor.getLong(idIndex).toString()
                val body = cursor.getString(bodyIndex) ?: ""
                val dateMillis = cursor.getLong(dateIndex)
                val type = cursor.getInt(typeIndex)
                val isMine = type == Telephony.Sms.MESSAGE_TYPE_SENT

                val message = mapOf(
                    "id" to "m-$id",
                    "text" to body,
                    "mine" to isMine,
                    "time" to android.text.format.DateFormat.format("h:mm", dateMillis).toString(),
                    "media" to false
                )

                val contactName = resolveContactName(address, contactNameCache)
                firstByAddress[address] = mapOf(
                    "id" to id,
                    "name" to contactName,
                    "phoneNumber" to address,
                    "preview" to body,
                    "lastSeen" to android.text.format.DateUtils.getRelativeTimeSpanString(
                        dateMillis,
                        System.currentTimeMillis(),
                        android.text.format.DateUtils.MINUTE_IN_MILLIS
                    ).toString(),
                    "unread" to 0,
                    "colors" to listOf(0xFF2F3640.toInt(), 0xFF5A6575.toInt()),
                    "messages" to listOf(message)
                )
            }
        }
        return firstByAddress.values.toList()
    }

    private fun resolveContactName(
        phoneNumber: String,
        cache: MutableMap<String, String>
    ): String {
        cache[phoneNumber]?.let { return it }

        val hasContactsPermission = ActivityCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_CONTACTS
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasContactsPermission) {
            cache[phoneNumber] = phoneNumber
            return phoneNumber
        }

        val uri = ContactsContract.PhoneLookup.CONTENT_FILTER_URI.buildUpon()
            .appendPath(Uri.encode(phoneNumber))
            .build()
        val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME)
        val name = contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getString(
                    cursor.getColumnIndexOrThrow(ContactsContract.PhoneLookup.DISPLAY_NAME)
                )
            } else {
                null
            }
        }

        val resolved = if (name.isNullOrBlank()) phoneNumber else name
        cache[phoneNumber] = resolved
        return resolved
    }

    private fun sendSms(call: MethodCall, result: MethodChannel.Result) {
        val recipient = call.argument<String>("recipient")
        val body = call.argument<String>("body")
        if (recipient.isNullOrBlank() || body.isNullOrBlank()) {
            result.success(false)
            return
        }

        val sendPermission = ActivityCompat.checkSelfPermission(
            this,
            Manifest.permission.SEND_SMS
        )
        if (sendPermission != PackageManager.PERMISSION_GRANTED) {
            result.success(false)
            return
        }

        return try {
            SmsManager.getDefault().sendTextMessage(recipient, null, body, null, null)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun composeMms(call: MethodCall, result: MethodChannel.Result) {
        val recipient = call.argument<String>("recipient")
        val body = call.argument<String>("body") ?: ""
        val attachmentPath = call.argument<String>("attachmentPath")
        if (recipient.isNullOrBlank() || attachmentPath.isNullOrBlank()) {
            result.success(false)
            return
        }

        return try {
            val file = File(attachmentPath)
            if (!file.exists()) {
                result.success(false)
                return
            }

            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/*"
                putExtra("address", recipient)
                putExtra("sms_body", body)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun startCall(call: MethodCall, result: MethodChannel.Result) {
        val recipient = call.argument<String>("recipient")
        if (recipient.isNullOrBlank()) {
            result.success(false)
            return
        }

        val callPermission = ActivityCompat.checkSelfPermission(
            this,
            Manifest.permission.CALL_PHONE
        )
        if (callPermission != PackageManager.PERMISSION_GRANTED) {
            result.success(false)
            return
        }

        return try {
            val intent = Intent(Intent.ACTION_CALL).apply {
                data = Uri.parse("tel:$recipient")
            }
            startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }
}
