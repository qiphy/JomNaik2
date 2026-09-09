import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../widgets/privacy_policy_screen.dart';

const _privacyPolicyVersion = '2026-08-04-v3';
const _privacyPolicyEffectiveDate = '4 August 2026';
const _privacyPolicyConsentKey = 'privacy_policy_consent_version';
const _privacyPolicyAcceptedAtKey = 'privacy_policy_accepted_at';

class StartupScreen extends StatefulWidget {
  final Widget nextScreen;
  final FlutterSecureStorage storage;

  const StartupScreen({
    super.key,
    required this.nextScreen,
    required this.storage,
  });

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  Timer? _startupTimer;

  @override
  void initState() {
    super.initState();
    _startupTimer = Timer(const Duration(milliseconds: 1600), () {
      _continueAfterSplash();
    });
  }

  Future<void> _savePrivacyConsent() async {
    await widget.storage.write(
      key: _privacyPolicyConsentKey,
      value: _privacyPolicyVersion,
    );
    await widget.storage.write(
      key: _privacyPolicyAcceptedAtKey,
      value: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _continueAfterSplash() async {
    final acceptedVersion = await widget.storage.read(
      key: _privacyPolicyConsentKey,
    );
    
    if (!mounted) return;
    
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => acceptedVersion == _privacyPolicyVersion
            ? widget.nextScreen
            : PrivacyPolicyScreen(
                effectiveDate: _privacyPolicyEffectiveDate,
                onSaveConsent: _savePrivacyConsent,
                homeBuilder: (_) => widget.nextScreen,
              ),
      ),
    );
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [Image.asset('assets/logo.png', width: 220, height: 220)],
        ),
      ),
    );
  }
}