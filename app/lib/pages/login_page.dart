import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(), _password = TextEditingController();
  final _name = TextEditingController(), _setup = TextEditingController();
  final _phone = TextEditingController();
  String _action = 'login';
  bool _demo = ApiService.demoMode, _busy = false, _setupRequired = false;
  String? _error, _setupFile;
  int _statusVersion = 0;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final version = ++_statusVersion;
    final demo = _demo;
    try {
      if (demo) {
        final setup = await ApiService.setupDealDemo();
        if (!mounted || version != _statusVersion) return;
        ApiService.demoDate = setup['business_date'] as String;
        ApiService.demoSessionDate =
            setup['session_started_date'] as String? ?? '';
      }
      final status = await ApiService.accountRequest(
        'GET',
        'auth/status',
        null,
        demo,
      );
      if (mounted && version == _statusVersion) {
        setState(() {
          _setupRequired = status['setup_required'] == true;
          _setupFile = status['setup_token_file'];
        });
      }
    } catch (_) {
      if (mounted && version == _statusVersion) {
        setState(
          () =>
              _error = 'Backend unavailable. Start the backend and try again.',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_email, _password, _name, _setup, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppProvider>().signInAccount(_action, {
        'email': _email.text.trim(),
        'password': _password.text,
        if (_action != 'login') 'name': _name.text.trim(),
        if (_action == 'register') 'phone': _phone.text.trim(),
        if (_action == 'setup') 'setup_token': _setup.text.trim(),
      }, demo: _demo);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'FreshFlow',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('Real accounts'),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text('Demo accounts'),
                        ),
                      ],
                      selected: {_demo},
                      onSelectionChanged: _busy
                          ? null
                          : (value) {
                              setState(() {
                                _demo = value.first;
                                _setupRequired = false;
                                _setupFile = null;
                                _action = 'login';
                                _error = null;
                                _password.clear();
                                _setup.clear();
                              });
                              _loadStatus();
                            },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _demo ? 'Demo account sign in' : 'Store account sign in',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (_demo)
                      const Text(
                        'Separate demo accounts with real sign-in and branch permissions. Existing simulated sales and inventory are kept.',
                      ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'login', label: Text('Sign in')),
                        ButtonSegment(
                          value: 'register',
                          label: Text('Customer sign up'),
                        ),
                      ],
                      selected: {_action == 'setup' ? 'login' : _action},
                      onSelectionChanged: _busy
                          ? null
                          : (value) => setState(() => _action = value.first),
                    ),
                    if (_setupRequired) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'First-time setup: create the administrator. Managers and staff are created from Account settings.',
                      ),
                      if (_setupFile != null)
                        Text('Local setup token file: data/$_setupFile'),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _action = 'setup'),
                        child: const Text('Create initial administrator'),
                      ),
                    ],
                    if (_action != 'login')
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Full name',
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Enter your name.'
                            : null,
                      ),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) => v != null && v.contains('@')
                          ? null
                          : 'Enter a valid email.',
                    ),
                    if (_action == 'register')
                      TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone (optional)',
                        ),
                      ),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: (v) =>
                          (v?.length ?? 0) < (_action == 'login' ? 1 : 12)
                          ? 'Use at least ${_action == 'login' ? 1 : 12} characters.'
                          : null,
                    ),
                    if (_action == 'setup')
                      TextFormField(
                        controller: _setup,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Local setup token',
                        ),
                        validator: (v) => v == null || v.isEmpty
                            ? 'Enter the token from the local setup file.'
                            : null,
                      ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(
                        _busy
                            ? 'Please wait...'
                            : _action == 'setup'
                            ? 'Create administrator'
                            : _action == 'register'
                            ? 'Create customer account'
                            : 'Sign in',
                      ),
                    ),
                    const Text(
                      'Employee access is limited to assigned branches. Sign out ends the session. Reloading the app requires signing in again.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
