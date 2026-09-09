import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.isSupabaseConfigured,
    required this.onStationLocationTrackingChanged,
  });

  final bool isSupabaseConfigured;
  final ValueChanged<bool> onStationLocationTrackingChanged;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _isSubmitting = false;
  bool _obscurePassword = true;
  String? _message;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isSubmitting = true;
      _message = null;
    });

    try {
      final auth = Supabase.instance.client.auth;
      if (_isSignUp) {
        final response = await auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (!mounted) return;
        setState(() {
          _message = response.session == null
              ? 'Check your email to confirm your new account.'
              : 'Your account is ready.';
        });
      } else {
        final response = await auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (!mounted) return;
        if (response.session == null || auth.currentSession == null) {
          setState(() {
            _message =
                'Supabase did not create a sign-in session. Confirm the account email, then try again.';
          });
        }
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not reach the account service.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isSupabaseConfigured) return const SupabaseSetupNotice();

    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final auth = Supabase.instance.client.auth;
        final user = auth.currentUser;
        if (user != null && auth.currentSession != null) {
          return SignedInProfile(
            user: user,
            onStationLocationTrackingChanged:
                widget.onStationLocationTrackingChanged,
          );
        }

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.account_circle, size: 72),
              const SizedBox(height: 16),
              Text(
                _isSignUp ? 'Create an account' : 'Welcome back',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isSignUp
                    ? 'Save your preferences and access them on any device.'
                    : 'Sign in to manage your JomNaik account.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || !value.contains('@')) {
                          return 'Enter a valid email address.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autofillHints: [
                        _isSignUp
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.length < 6) {
                          return 'Password must contain at least 6 characters.';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ],
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color:
                        _message!.startsWith('Could') ||
                            _message!.startsWith('Invalid')
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_isSignUp ? 'Sign up' : 'Sign in'),
                ),
              ),
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () => setState(() {
                        _isSignUp = !_isSignUp;
                        _message = null;
                      }),
                child: Text(
                  _isSignUp
                      ? 'Already have an account? Sign in'
                      : 'New to JomNaik? Sign up',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SignedInProfile extends StatefulWidget {
  const SignedInProfile({
    super.key,
    required this.user,
    required this.onStationLocationTrackingChanged,
  });

  final User user;
  final ValueChanged<bool> onStationLocationTrackingChanged;

  @override
  State<SignedInProfile> createState() => _SignedInProfileState();
}

class _SignedInProfileState extends State<SignedInProfile> {
  bool _isSavingLocationTracking = false;

  bool get _locationTrackingEnabled =>
      widget.user.userMetadata?['station_location_tracking'] == true;

  Future<void> _setLocationTrackingEnabled(bool enabled) async {
    setState(() => _isSavingLocationTracking = true);
    try {
      final metadata = Map<String, dynamic>.from(
        widget.user.userMetadata ?? {},
      );
      metadata['station_location_tracking'] = enabled;
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(data: metadata),
      );
      widget.onStationLocationTrackingChanged(enabled);
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the tracking preference.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingLocationTracking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.account_circle, size: 72),
            const SizedBox(height: 16),
            Text(
              'You are signed in',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              widget.user.email ?? 'JomNaik account',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.location_searching),
              title: const Text('Station location tracking'),
              subtitle: const Text(
                'Ask which nearby station or stop you are at when an interchange has stops within 20 metres.',
              ),
              value: _locationTrackingEnabled,
              onChanged: _isSavingLocationTracking
                  ? null
                  : _setLocationTrackingEnabled,
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => Supabase.instance.client.auth.signOut(),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

class SupabaseSetupNotice extends StatelessWidget {
  const SupabaseSetupNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 64),
            const SizedBox(height: 20),
            Text(
              'Account sign-in is being set up',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'Add this app\'s Supabase URL and publishable key when building the app to enable sign-in and sign-up.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}