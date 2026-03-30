import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MessageApp());

class MessageApp extends StatefulWidget {
  const MessageApp({super.key});

  @override
  State<MessageApp> createState() => _MessageAppState();
}

class _MessageAppState extends State<MessageApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lightTheme = ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF2F3640),
        secondary: Color(0xFF5A6575),
        surface: Color(0xFFFFFFFF),
      ),
      textTheme: GoogleFonts.plusJakartaSansTextTheme(
        ThemeData.light().textTheme,
      ),
    );
    final darkTheme = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF0D1117),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFD0D5DD),
        secondary: Color(0xFF98A2B3),
        surface: Color(0xFF1D2430),
      ),
      textTheme: GoogleFonts.plusJakartaSansTextTheme(
        ThemeData.dark().textTheme,
      ),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'sasi',
      themeMode: _themeMode,
      theme: lightTheme,
      darkTheme: darkTheme,
      home: InboxPage(
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.onToggleTheme,
  });

  final VoidCallback onToggleTheme;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final AndroidMessagingBridge _bridge = AndroidMessagingBridge();
  final TextEditingController _search = TextEditingController();
  List<Conversation> _items = List<Conversation>.from(seedConversations);
  final Set<String> _mutedConversationIds = <String>{};
  final Set<String> _pinnedConversationIds = <String>{};
  final Set<String> _archivedConversationIds = <String>{};
  final Set<String> _blockedConversationIds = <String>{};
  bool _loading = true;
  bool _defaultApp = false;
  int _tabIndex = 0;
  bool _messageNotifications = true;
  bool _privateChats = true;
  bool _groupChats = true;
  bool _doNotDisturb = false;
  String? _profileImagePath;

  @override
  void initState() {
    super.initState();
    unawaited(_startupSync());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _startupSync() async {
    if (!await _bridge.isAndroidDevice()) {
      setState(() {
        _loading = false;
      });
      return;
    }

    var isDefault = await _bridge.isDefaultSmsApp();
    if (!isDefault) {
      await _bridge.requestDefaultSmsRole();
      isDefault = await _bridge.isDefaultSmsApp();
    }

    final permissionOk = await _ensurePermissions();
    if (!permissionOk && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please allow SMS, Contacts, and Phone permissions.')),
      );
    }

    final synced = await _bridge.fetchConversations();

    if (!mounted) return;
    setState(() {
      if (synced.isNotEmpty) _items = synced;
      _defaultApp = isDefault;
      _loading = false;
    });
  }

  Future<bool> _ensurePermissions() async {
    final permissions = [
      Permission.sms,
      Permission.phone,
      Permission.contacts,
    ];
    final statuses = await permissions.request();
    final allGranted = statuses.values.every((status) => status.isGranted || status.isLimited);
    if (allGranted) return true;

    final permanentlyDenied = statuses.values.any((status) => status.isPermanentlyDenied);
    if (permanentlyDenied && mounted) {
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Access needed'),
          content: const Text(
            'SMS, Contacts, and Phone access must be allowed in Android settings for this app to work.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        await openAppSettings();
      }
    }
    return false;
  }

  Future<void> _refresh() async {
    final synced = await _bridge.fetchConversations();
    if (!mounted) return;
    setState(() {
      if (synced.isNotEmpty) _items = synced;
    });
  }

  Future<void> _makeDefault() async {
    final ok = await _bridge.requestDefaultSmsRole();
    if (ok) {
      await _ensurePermissions();
      await _refresh();
    }
    if (!mounted) return;
    setState(() {
      _defaultApp = ok;
    });
  }

  Future<void> _pickProfilePhoto() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.single.path == null) return;
    setState(() {
      _profileImagePath = result.files.single.path;
    });
  }

  Future<void> _openChat(Conversation item) async {
    final updated = await Navigator.of(context).push<Conversation>(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          conversation: item,
          bridge: _bridge,
        ),
      ),
    );
    if (!mounted || updated == null) return;
    setState(() {
      final idx = _items.indexWhere((e) => e.id == updated.id);
      if (idx != -1) _items[idx] = updated;
    });
  }

  Future<void> _startCallFromInbox(String number) async {
    final granted = await Permission.phone.request();
    if (!granted.isGranted) {
      if (granted.isPermanentlyDenied) {
        await openAppSettings();
      }
      return;
    }
    await _bridge.startCall(number);
  }

  void _applyChatAction(String action, Conversation item) {
    setState(() {
      switch (action) {
        case 'pin':
          if (_pinnedConversationIds.contains(item.id)) {
            _pinnedConversationIds.remove(item.id);
          } else {
            _pinnedConversationIds.add(item.id);
          }
          break;
        case 'archive':
          _archivedConversationIds.add(item.id);
          break;
        case 'delete':
          _items = _items.where((element) => element.id != item.id).toList();
          _pinnedConversationIds.remove(item.id);
          _archivedConversationIds.remove(item.id);
          _mutedConversationIds.remove(item.id);
          _blockedConversationIds.remove(item.id);
          break;
        case 'block':
          _blockedConversationIds.add(item.id);
          break;
      }
    });
  }

  Future<void> _startNewMessageFlow() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    final created = await showDialog<Conversation>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('New message'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name (optional)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final phone = phoneController.text.trim();
                final name = nameController.text.trim();
                if (phone.isEmpty) return;
                final found = _items.where((e) => e.phoneNumber == phone).toList();
                if (found.isNotEmpty) {
                  Navigator.of(dialogContext).pop(found.first);
                  return;
                }

                final nowId = DateTime.now().microsecondsSinceEpoch.toString();
                Navigator.of(dialogContext).pop(
                  Conversation(
                    id: 'new-$nowId',
                    name: name.isEmpty ? phone : name,
                    phoneNumber: phone,
                    preview: '',
                    lastSeen: 'Now',
                    unread: 0,
                    colors: const [Color(0xFF2F3640), Color(0xFF5A6575)],
                    messages: const [],
                  ),
                );
              },
              child: const Text('Start'),
            ),
          ],
        );
      },
    );

    nameController.dispose();
    phoneController.dispose();

    if (created == null) return;
    final exists = _items.any((e) => e.id == created.id);
    if (!exists) {
      setState(() {
        _items = [created, ..._items];
        _tabIndex = 0;
      });
    }
    await _openChat(created);
  }

  void _openQuickMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.message_outlined),
                title: const Text('New message'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_startNewMessageFlow());
                },
              ),
              ListTile(
                leading: const Icon(Icons.contacts_outlined),
                title: const Text('Contacts'),
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() => _tabIndex = 1);
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() => _tabIndex = 2);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topGradient = isDark
        ? const [Color(0xFF111821), Color(0xFF0D141C), Color(0xFF090F15)]
        : const [Color(0xFFF8FAFC), Color(0xFFF2F5F9), Color(0xFFEEF2F7)];
    final panelColor = isDark ? const Color(0xD90B1118) : const Color(0xF2FFFFFF);
    final q = _search.text.trim().toLowerCase();
    final filtered = _items.where((e) {
      if (_archivedConversationIds.contains(e.id) || _blockedConversationIds.contains(e.id)) {
        return false;
      }
      if (q.isEmpty) return true;
      return e.name.toLowerCase().contains(q) || e.preview.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) {
        final aPinned = _pinnedConversationIds.contains(a.id);
        final bPinned = _pinnedConversationIds.contains(b.id);
        if (aPinned == bPinned) return 0;
        return aPinned ? -1 : 1;
      });
    final subtitle = _tabIndex == 0
        ? 'Chats'
        : _tabIndex == 1
            ? 'Contacts'
            : 'Settings';
    final searchHint = _tabIndex == 1 ? 'Search contacts' : 'Search messages';

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: topGradient,
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _IconChip(icon: Icons.menu_rounded, onTap: _openQuickMenu),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('sasi', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                              Text(
                                subtitle,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: isDark ? Colors.white70 : const Color(0xFF475467),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 48, height: 48),
                      ],
                    ),
                    if (!_defaultApp && _tabIndex == 0) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: isDark
                                ? const [Color(0xFF1A2633), Color(0xFF151E29)]
                                : const [Color(0xFFFFFFFF), Color(0xFFF3F6FA)],
                          ),
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : const Color(0xFFF2F4F7),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(Icons.sms_rounded, color: Theme.of(context).colorScheme.primary),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                'Set this app as default.',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: isDark ? Colors.white70 : const Color(0xFF475467),
                                    ),
                              ),
                            ),
                            FilledButton(
                              onPressed: _makeDefault,
                              child: const Text('Set Default'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: searchHint,
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: isDark ? const Color(0xFF1A232E) : const Color(0xFFFFFFFF),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: panelColor,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                  ),
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _tabIndex == 0
                          ? RefreshIndicator(
                              onRefresh: _refresh,
                              child: ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(20, 18, 20, 110),
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 12),
                                itemBuilder: (_, i) {
                                  final item = filtered[i];
                                  return _ConversationTile(
                                    item: item,
                                    pinned: _pinnedConversationIds.contains(item.id),
                                    muted: _mutedConversationIds.contains(item.id),
                                    onTap: () => _openChat(item),
                                    onActionSelected: (action) => _applyChatAction(action, item),
                                  );
                                },
                              ),
                            )
                          : _tabIndex == 1
                              ? ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 110),
                                  itemCount: filtered.length,
                                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                                  itemBuilder: (_, i) {
                                    final item = filtered[i];
                                    final muted = _mutedConversationIds.contains(item.id);
                                    return Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: isDark ? const Color(0xFF161E28) : Colors.white,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        children: [
                                          _Avatar(name: item.name, colors: item.colors, size: 50),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(item.name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                                                Text(item.phoneNumber, style: Theme.of(context).textTheme.bodySmall),
                                              ],
                                            ),
                                          ),
                                          _MiniAction(
                                            label: 'Message',
                                            onTap: () => _openChat(item),
                                          ),
                                          const SizedBox(width: 8),
                                          _MiniAction(
                                            label: 'Call',
                                            onTap: () => _startCallFromInbox(item.phoneNumber),
                                          ),
                                          const SizedBox(width: 8),
                                          _MiniAction(
                                            label: muted ? 'Unmute' : 'Mute',
                                            onTap: () {
                                              setState(() {
                                                if (muted) {
                                                  _mutedConversationIds.remove(item.id);
                                                } else {
                                                  _mutedConversationIds.add(item.id);
                                                }
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                )
                              : ListView(
                                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 110),
                                  children: [
                                    Container(
                                      margin: const EdgeInsets.only(bottom: 12),
                                      padding: const EdgeInsets.all(18),
                                      decoration: BoxDecoration(
                                        color: isDark ? const Color(0xFF161E28) : Colors.white,
                                        borderRadius: BorderRadius.circular(22),
                                      ),
                                      child: Row(
                                        children: [
                                          _ProfileAvatar(
                                            imagePath: _profileImagePath,
                                            size: 64,
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  'Profile photo',
                                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  'Update your picture',
                                                  style: Theme.of(context).textTheme.bodySmall,
                                                ),
                                              ],
                                            ),
                                          ),
                                          FilledButton(
                                            onPressed: _pickProfilePhoto,
                                            child: const Text('Update'),
                                          ),
                                        ],
                                      ),
                                    ),
                                    _SwitchTile(
                                      title: 'Message notifications',
                                      value: _messageNotifications,
                                      onChanged: (v) => setState(() => _messageNotifications = v),
                                    ),
                                    _SwitchTile(
                                      title: 'Private chats',
                                      value: _privateChats,
                                      onChanged: (v) => setState(() => _privateChats = v),
                                    ),
                                    _SwitchTile(
                                      title: 'Group chats',
                                      value: _groupChats,
                                      onChanged: (v) => setState(() => _groupChats = v),
                                    ),
                                    _SwitchTile(
                                      title: 'Do not disturb',
                                      value: _doNotDisturb,
                                      onChanged: (v) => setState(() => _doNotDisturb = v),
                                    ),
                                  ],
                                ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF151E28) : Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Expanded(
                child: _NavTab(
                  icon: Icons.home_rounded,
                  label: 'Chats',
                  selected: _tabIndex == 0,
                  onTap: () => setState(() => _tabIndex = 0),
                ),
              ),
              Expanded(
                child: _NavTab(
                  icon: Icons.contacts_rounded,
                  label: 'Contacts',
                  selected: _tabIndex == 1,
                  onTap: () => setState(() => _tabIndex = 1),
                ),
              ),
              Expanded(
                child: _NavTab(
                  icon: Icons.settings_rounded,
                  label: 'Settings',
                  selected: _tabIndex == 2,
                  onTap: () => setState(() => _tabIndex = 2),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _tabIndex == 0
          ? FloatingActionButton(
              onPressed: _startNewMessageFlow,
              child: const Icon(Icons.edit_rounded),
            )
          : null,
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.conversation, required this.bridge});

  final Conversation conversation;
  final AndroidMessagingBridge bridge;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late Conversation _conversation;
  final TextEditingController _composer = TextEditingController();
  String? _attachmentPath;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _conversation = widget.conversation;
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.media, allowMultiple: false);
    if (result == null || result.files.single.path == null) return;
    setState(() => _attachmentPath = result.files.single.path);
  }

  void _insertEmoji(String emoji) {
    final value = _composer.value;
    final selection = value.selection;
    final start = selection.start >= 0 ? selection.start : value.text.length;
    final end = selection.end >= 0 ? selection.end : value.text.length;
    final newText = value.text.replaceRange(start, end, emoji);
    final cursor = start + emoji.length;
    _composer.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  Future<void> _openEmojiPicker() async {
    final emojis = ['😀', '😂', '😍', '😎', '😭', '👍', '🙏', '🔥', '❤️', '🎉', '🤝', '😴'];
    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: emojis
              .map(
                (emoji) => InkWell(
                  onTap: () => Navigator.of(context).pop(emoji),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );

    if (selected != null) {
      _insertEmoji(selected);
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty && _attachmentPath == null) return;

    final smsPermission = await Permission.sms.request();
    if (!smsPermission.isGranted) {
      if (smsPermission.isPermanentlyDenied) {
        await openAppSettings();
      }
      return;
    }

    setState(() => _sending = true);
    final ok = _attachmentPath == null
        ? await widget.bridge.sendSms(recipient: _conversation.phoneNumber, body: text)
        : await widget.bridge.composeMms(
            recipient: _conversation.phoneNumber,
            body: text,
            attachmentPath: _attachmentPath!,
          );
    if (!mounted) return;
    setState(() => _sending = false);

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message action failed on Android. Check permissions/default-app access.')),
      );
      return;
    }

    final outgoing = MessageItem(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      text: text.isEmpty ? 'MMS attachment' : text,
      mine: true,
      time: formatTime(DateTime.now()),
      media: _attachmentPath != null,
    );

    setState(() {
      _conversation = _conversation.copyWith(
        preview: outgoing.text,
        lastSeen: 'Just now',
        messages: [..._conversation.messages, outgoing],
      );
      _composer.clear();
      _attachmentPath = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chatGradient = isDark
        ? const [Color(0xFF141C26), Color(0xFF101822), Color(0xFF0A1118)]
        : const [Color(0xFFF8FAFC), Color(0xFFF2F5F9), Color(0xFFEEF2F7)];
    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(_conversation);
        return false;
      },
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: chatGradient,
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                  child: Row(
                    children: [
                      _IconChip(icon: Icons.arrow_back_ios_new_rounded, onTap: () => Navigator.of(context).pop(_conversation)),
                      const SizedBox(width: 12),
                      _Avatar(name: _conversation.name, colors: _conversation.colors, size: 48),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_conversation.name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                            Text(
                              'Available now',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.secondary,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      _IconChip(
                        icon: Icons.call_outlined,
                        onTap: () async {
                          final granted = await Permission.phone.request();
                          if (!granted.isGranted) {
                            if (granted.isPermanentlyDenied) {
                              await openAppSettings();
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Phone permission is required to place calls.')),
                              );
                            }
                            return;
                          }
                          final started = await widget.bridge.startCall(_conversation.phoneNumber);
                          if (!started && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Unable to start call right now.')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                    itemCount: _conversation.messages.length,
                    itemBuilder: (_, i) => _Bubble(item: _conversation.messages[i], colors: _conversation.colors),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF151E28) : const Color(0xFFFFFFFF),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  ),
                  child: Column(
                    children: [
                      if (_attachmentPath != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1A232E) : const Color(0xFFF2F4F7),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.image_outlined, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 10),
                              Expanded(child: Text(_attachmentPath!.split('\\').last, overflow: TextOverflow.ellipsis)),
                              IconButton(onPressed: () => setState(() => _attachmentPath = null), icon: const Icon(Icons.close_rounded)),
                            ],
                          ),
                        ),
                      Row(
                        children: [
                          _IconChip(icon: Icons.emoji_emotions_outlined, onTap: _openEmojiPicker),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _composer,
                              minLines: 1,
                              maxLines: 5,
                              decoration: InputDecoration(
                                hintText: _attachmentPath == null ? 'Type message...' : 'Add MMS caption...',
                                filled: true,
                                fillColor: isDark ? const Color(0xFF1A232E) : const Color(0xFFF2F4F7),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _IconChip(icon: Icons.add_photo_alternate_outlined, onTap: _attach),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: _sending ? null : _send,
                            child: Container(
                              width: 58,
                              height: 58,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.primary,
                                    Theme.of(context).colorScheme.secondary,
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: _sending
                                  ? const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                    )
                                  : const Icon(Icons.send_rounded, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AndroidMessagingBridge {
  static const MethodChannel _channel = MethodChannel('pulse/messages');

  Future<bool> isAndroidDevice() async => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> isDefaultSmsApp() async {
    if (!await isAndroidDevice()) return false;
    return (await _channel.invokeMethod<bool>('isDefaultSmsApp')) ?? false;
  }

  Future<bool> requestDefaultSmsRole() async {
    if (!await isAndroidDevice()) return false;
    return (await _channel.invokeMethod<bool>('requestDefaultSmsApp')) ?? false;
  }

  Future<List<Conversation>> fetchConversations() async {
    if (!await isAndroidDevice()) return [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>('fetchConversations');
      if (raw == null) return [];
      return raw.whereType<Map>().map((e) => Conversation.fromMap(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> sendSms({required String recipient, required String body}) async {
    if (!await isAndroidDevice()) return false;
    return (await _channel.invokeMethod<bool>('sendSms', {'recipient': recipient, 'body': body})) ?? false;
  }

  Future<bool> composeMms({required String recipient, required String body, required String attachmentPath}) async {
    if (!await isAndroidDevice()) return false;
    return (await _channel.invokeMethod<bool>('composeMms', {
          'recipient': recipient,
          'body': body,
          'attachmentPath': attachmentPath,
        })) ??
        false;
  }

  Future<bool> startCall(String recipient) async {
    if (!await isAndroidDevice()) return false;
    return (await _channel.invokeMethod<bool>('startCall', {
          'recipient': recipient,
        })) ??
        false;
  }
}

class Conversation {
  const Conversation({
    required this.id,
    required this.name,
    required this.phoneNumber,
    required this.preview,
    required this.lastSeen,
    required this.unread,
    required this.colors,
    required this.messages,
  });

  final String id;
  final String name;
  final String phoneNumber;
  final String preview;
  final String lastSeen;
  final int unread;
  final List<Color> colors;
  final List<MessageItem> messages;

  Conversation copyWith({
    String? preview,
    String? lastSeen,
    List<MessageItem>? messages,
  }) {
    return Conversation(
      id: id,
      name: name,
      phoneNumber: phoneNumber,
      preview: preview ?? this.preview,
      lastSeen: lastSeen ?? this.lastSeen,
      unread: unread,
      colors: colors,
      messages: messages ?? this.messages,
    );
  }

  factory Conversation.fromMap(Map<String, dynamic> map) {
    final colors = (map['colors'] as List<dynamic>? ?? [0xFF2F3640, 0xFF5A6575]).cast<int>().map(Color.new).toList();
    final messages = (map['messages'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => MessageItem.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    return Conversation(
      id: '${map['id']}',
      name: map['name'] as String? ?? 'Unknown',
      phoneNumber: map['phoneNumber'] as String? ?? '',
      preview: map['preview'] as String? ?? '',
      lastSeen: map['lastSeen'] as String? ?? '',
      unread: map['unread'] as int? ?? 0,
      colors: colors,
      messages: messages,
    );
  }
}

class MessageItem {
  const MessageItem({
    required this.id,
    required this.text,
    required this.mine,
    required this.time,
    this.media = false,
  });

  final String id;
  final String text;
  final bool mine;
  final String time;
  final bool media;

  factory MessageItem.fromMap(Map<String, dynamic> map) {
    return MessageItem(
      id: '${map['id']}',
      text: map['text'] as String? ?? '',
      mine: map['mine'] as bool? ?? false,
      time: map['time'] as String? ?? '',
      media: map['media'] as bool? ?? false,
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF253142) : const Color(0xFFEFF3F8),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.imagePath,
    required this.size,
  });

  final String? imagePath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasImage = imagePath != null && imagePath!.isNotEmpty;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isDark ? const Color(0xFF253142) : const Color(0xFFE5E7EB),
        image: hasImage
            ? DecorationImage(
                image: FileImage(File(imagePath!)),
                fit: BoxFit.cover,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: hasImage
          ? null
          : Text(
              'ME',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : const Color(0xFF344054),
                  ),
            ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161E28) : Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: SwitchListTile(
        title: Text(title),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.secondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fg),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.item,
    required this.onTap,
    required this.onActionSelected,
    this.pinned = false,
    this.muted = false,
  });

  final Conversation item;
  final VoidCallback onTap;
  final ValueChanged<String> onActionSelected;
  final bool pinned;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Ink(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF161E28) : const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            _Avatar(name: item.name, colors: item.colors, size: 56),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(item.name, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                      Text(
                        item.lastSeen,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isDark ? Colors.white54 : const Color(0xFF667085),
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF222D3A) : const Color(0xFFF2F4F7),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      item.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: isDark ? Colors.white70 : const Color(0xFF475467),
                          ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              children: [
                PopupMenuButton<String>(
                  onSelected: onActionSelected,
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: 'pin',
                      child: Text(pinned ? 'Unpin chat' : 'Pin chat'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'archive',
                      child: Text('Archive chat'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'block',
                      child: Text('Block chat'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('Delete chat'),
                    ),
                  ],
                  child: Icon(
                    Icons.more_vert_rounded,
                    color: isDark ? Colors.white70 : const Color(0xFF667085),
                  ),
                ),
                if (pinned) const Icon(Icons.push_pin_rounded, size: 16),
                if (muted) const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(Icons.volume_off_rounded, size: 16),
                ),
                if (item.unread > 0)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: item.colors),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text('${item.unread}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.item, required this.colors});

  final MessageItem item;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final align = item.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: align,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: item.mine ? LinearGradient(colors: colors) : null,
            color: item.mine ? null : (isDark ? const Color(0xFF1B2632) : const Color(0xFFF2F4F7)),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.media) ...[
                const Icon(Icons.image_outlined, size: 18),
                const SizedBox(width: 8),
              ],
              Flexible(child: Text(item.text)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(item.time, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white54)),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _StoryItem extends StatelessWidget {
  const _StoryItem({required this.item});

  final Conversation item;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: item.colors),
            shape: BoxShape.circle,
          ),
          child: _Avatar(
            name: item.name,
            colors: isDark
                ? const [Color(0xFF1A232E), Color(0xFF1A232E)]
                : const [Color(0xFFE4E7EC), Color(0xFFE4E7EC)],
            size: 54,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 68,
          child: Text(item.name.split(' ').first, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.colors, required this.size});

  final String name;
  final List<Color> colors;
  final double size;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.first,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initials(name),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : Colors.white,
            ),
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFF2F4F7),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Icon(icon, color: isDark ? Colors.white : const Color(0xFF344054)),
      ),
    );
  }
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, parts.first.length > 1 ? 2 : 1).toUpperCase();
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

String formatTime(DateTime value) {
  final h = value.hour == 0 ? 12 : (value.hour > 12 ? value.hour - 12 : value.hour);
  final m = value.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

const seedConversations = <Conversation>[
  Conversation(
    id: '1',
    name: 'Daniel Garcia',
    phoneNumber: '+1555000101',
    preview: 'I will send the final visuals tonight.',
    lastSeen: '2m ago',
    unread: 2,
    colors: [Color(0xFF2F3640), Color(0xFF5A6575)],
    messages: [
      MessageItem(id: '1', text: 'Hi, the concepts look strong.', mine: false, time: '9:12'),
      MessageItem(id: '2', text: 'Perfect. Send me the final version.', mine: true, time: '9:14'),
      MessageItem(id: '3', text: 'I will send the final visuals tonight.', mine: false, time: '9:18'),
    ],
  ),
  Conversation(
    id: '2',
    name: 'Jenny Wilson',
    phoneNumber: '+1555000102',
    preview: 'Sure, I will be there in five.',
    lastSeen: '5m ago',
    unread: 0,
    colors: [Color(0xFF2F3640), Color(0xFF5A6575)],
    messages: [
      MessageItem(id: '4', text: 'Can you meet at the cafe?', mine: true, time: '8:32'),
      MessageItem(id: '5', text: 'Sure, I will be there in five.', mine: false, time: '8:34'),
    ],
  ),
  Conversation(
    id: '3',
    name: 'Kristin Watson',
    phoneNumber: '+1555000103',
    preview: 'Keep you in the loop!',
    lastSeen: '9:45',
    unread: 1,
    colors: [Color(0xFF2F3640), Color(0xFF5A6575)],
    messages: [
      MessageItem(id: '6', text: 'Keep you in the loop!', mine: false, time: '9:45'),
    ],
  ),
  Conversation(
    id: '4',
    name: 'Arlene McCoy',
    phoneNumber: '+1555000104',
    preview: 'I will take a look before lunch.',
    lastSeen: 'Yesterday',
    unread: 0,
    colors: [Color(0xFF2F3640), Color(0xFF5A6575)],
    messages: [
      MessageItem(id: '7', text: 'I will take a look before lunch.', mine: false, time: 'Yesterday'),
    ],
  ),
];
