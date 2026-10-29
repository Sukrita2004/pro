import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../data/store_catalog.dart';

class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key});
  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  List<Map<String, dynamic>> _users = [];
  Map<String, dynamic>? _backups;
  bool _busy = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<AppProvider>();
    setState(() => _busy = true);
    try {
      if (provider.role == 'manager') {
        final rows = await ApiService.accountRequest('GET', 'auth/users');
        _users = List<Map<String, dynamic>>.from(rows);
      }
      if (provider.isAccountAdmin) {
        _backups = Map<String, dynamic>.from(
          await ApiService.accountRequest('GET', 'admin/backups'),
        );
      }
    } catch (error) {
      _message = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    final old = TextEditingController();
    final fresh = TextEditingController();
    final change = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change your password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: old,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            TextField(
              controller: fresh,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password (12+ characters)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Change password'),
          ),
        ],
      ),
    );
    if (change == true && mounted) {
      try {
        await ApiService.accountRequest('POST', 'auth/password', {
          'current_password': old.text,
          'new_password': fresh.text,
        });
        if (mounted) {
          context.read<AppProvider>().setRole(null);
          Navigator.pop(context);
        }
      } catch (error) {
        if (mounted) setState(() => _message = error.toString());
      }
    }
    old.dispose();
    fresh.dispose();
  }

  Future<void> _profile() async {
    final p = context.read<AppProvider>();
    final name = TextEditingController(text: p.currentUser?['name']);
    final phone = TextEditingController(text: p.currentUser?['phone']);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit my profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save profile'),
          ),
        ],
      ),
    );
    if (saved == true) {
      try {
        await p.updateAccountProfile(name.text, phone.text);
      } catch (error) {
        if (mounted) setState(() => _message = error.toString());
      }
    }
    name.dispose();
    phone.dispose();
  }

  Future<void> _employee([Map<String, dynamic>? existing]) async {
    final provider = context.read<AppProvider>();
    final name = TextEditingController(text: existing?['name']);
    final email = TextEditingController(text: existing?['email']);
    final password = TextEditingController();
    var role = existing?['role'] as String? ?? 'staff';
    var active = existing?['active'] == null || existing?['active'] == 1;
    final stores = Set<String>.from(
      existing?['stores'] ?? [provider.accessibleStoreIds.first],
    );
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(
            existing == null ? 'Create employee account' : 'Manage employee',
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    enabled: existing == null,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  TextField(
                    controller: email,
                    enabled: existing == null,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  TextField(
                    controller: password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: existing == null
                          ? 'Initial password (12+ characters)'
                          : 'Reset password (leave blank to keep)',
                    ),
                  ),
                  if (existing == null && provider.isAccountAdmin)
                    DropdownButton<String>(
                      value: role,
                      items: ['staff', 'manager']
                          .map(
                            (r) => DropdownMenuItem(value: r, child: Text(r)),
                          )
                          .toList(),
                      onChanged: (v) => update(() => role = v!),
                    ),
                  for (final store
                      in (role == 'customer'
                          ? <String>[]
                          : provider.accessibleStoreIds))
                    CheckboxListTile(
                      dense: true,
                      title: Text(storeName(store)),
                      value: stores.contains(store),
                      onChanged: (checked) => update(() {
                        if (checked == true) {
                          stores.add(store);
                        } else {
                          stores.remove(store);
                        }
                      }),
                    ),
                  if (existing != null)
                    SwitchListTile(
                      title: const Text('Account enabled'),
                      value: active,
                      onChanged: (v) => update(() => active = v),
                    ),
                  const Text(
                    'Disabling, resetting a password or changing branches ends all sessions for this account.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      try {
        if (existing == null) {
          await ApiService.accountRequest('POST', 'auth/users', {
            'name': name.text,
            'email': email.text,
            'password': password.text,
            'role': role,
            'stores': stores.toList(),
          });
        } else {
          await ApiService.accountRequest(
            'PATCH',
            'auth/users/${existing['user_id']}',
            {
              'active': active,
              if (role != 'customer') 'stores': stores.toList(),
              if (password.text.isNotEmpty) 'password': password.text,
            },
          );
        }
        if (mounted) {
          setState(
            () => _message = 'Account saved. Share credentials privately.',
          );
          await _load();
        }
      } catch (error) {
        if (mounted) setState(() => _message = error.toString());
      }
    }
    name.dispose();
    email.dispose();
    password.dispose();
  }

  Future<void> _backup([String? id]) async {
    setState(() => _busy = true);
    try {
      final result = await ApiService.accountRequest(
        'POST',
        id == null ? 'admin/backups' : 'admin/backups/$id/verify',
      );
      if (mounted) {
        setState(
          () => _message = id == null
              ? 'Backup created and integrity checked.'
              : 'Restore test passed: ${result['scopes']}. Live data was not changed.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          ApiService.demoMode ? 'Demo account settings' : 'Account settings',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('${p.currentUser?['name']} | ${p.currentUser?['email']}'),
          Text('Role: ${p.currentUser?['role']}'),
          if (ApiService.demoMode)
            const Text(
              'Demo accounts and simulated trading records. Separate from real accounts.',
            ),
          Text(
            'Phone: ${(p.currentUser?['phone'] as String?)?.isNotEmpty == true ? p.currentUser!['phone'] : 'Not provided'}',
          ),
          OutlinedButton(
            onPressed: _busy ? null : _profile,
            child: const Text('Edit my profile'),
          ),
          Text(
            p.isAccountAdmin
                ? 'Administrator: all branches'
                : p.role == 'customer'
                ? 'Customer: browse offers at all branches'
                : 'Assigned branches: ${p.accessibleStoreIds.map(storeName).join(', ')}',
          ),
          OutlinedButton(
            onPressed: _busy ? null : _changePassword,
            child: const Text('Change my password'),
          ),
          if (_message != null) Text(_message!),
          if (_busy) const LinearProgressIndicator(),
          if (p.role == 'manager') ...[
            const Divider(),
            const Text(
              'Employee accounts',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            FilledButton(
              onPressed: _busy ? null : () => _employee(),
              child: const Text('Create employee'),
            ),
            for (final user in _users)
              ListTile(
                title: Text('${user['name']} (${user['role']})'),
                subtitle: Text(
                  '${user['email']} | ${user['active'] == 1 ? 'Enabled' : 'Disabled'} | ${(user['stores'] as List).join(', ')}',
                ),
                trailing: user['role'] == 'admin'
                    ? null
                    : IconButton(
                        tooltip: 'Manage employee',
                        icon: const Icon(Icons.manage_accounts_outlined),
                        onPressed: _busy ? null : () => _employee(user),
                      ),
              ),
          ],
          if (p.isAccountAdmin) ...[
            const Divider(),
            const Text(
              'Database backups',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              ApiService.demoMode
                  ? 'Automatic demo backup once per Thailand date while the backend runs. Files stay in backups/demo_accounts/. Includes all simulated trading data. Real account backups cannot be accessed here.'
                  : 'Automatic backup once per Thailand date while the backend runs. Files stay on the server in backups/. No automatic deletion; monitor free disk space. Keep an additional copy on separate storage.',
            ),
            const Text(
              'Backups contain account and business data. Restore is performed offline into a new database file; existing data is never overwritten here.',
            ),
            if (_backups?['last_error'] != null)
              Text('Automatic backup failed: ${_backups!['last_error']}'),
            FilledButton(
              onPressed: _busy ? null : () => _backup(),
              child: const Text('Back up now'),
            ),
            for (final row in (_backups?['backups'] as List? ?? []))
              Card(
                child: ListTile(
                  title: Text('${row['bangkok_date']} | ${row['reason']}'),
                  subtitle: Text(
                    '${row['backup_id']}\nIntegrity: ${row['integrity']} | ${(row['files'] as List).map((f) => f['scope']).join(', ')}',
                  ),
                  trailing: TextButton(
                    onPressed: _busy ? null : () => _backup(row['backup_id']),
                    child: const Text('Test restore'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
