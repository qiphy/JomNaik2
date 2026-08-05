import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({
    super.key,
    required this.effectiveDate,
    required this.onSaveConsent,
    required this.homeBuilder,
  });

  final String effectiveDate;
  final Future<void> Function() onSaveConsent;
  final WidgetBuilder homeBuilder;

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  bool _accepted = false;
  bool _saving = false;

  Future<void> _acceptAndContinue() async {
    if (!_accepted || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSaveConsent();
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute<void>(builder: widget.homeBuilder));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save your privacy choice.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy and data')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'JomNaik Privacy Policy',
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Effective ${widget.effectiveDate} • Beta version',
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 20),
                    const _PrivacySection(
                      title: 'What JomNaik uses',
                      body:
                          'When you grant location permission, the app uses your location to show your position, find nearby stops and plan journeys. During active live journey guidance, location updates advance your next-step instruction and can be used to replan from your current location. Map-centre coordinates are sent to the routing and weather services when you search or move the map. When a live-guided journey reaches its destination, a small trip summary (destination name, duration, modes and completion time) is saved only in encrypted storage on your device, with a maximum of 20 summaries. You can use the app without granting location permission by searching for places manually.',
                    ),
                    const _PrivacySection(
                      title: 'Optional station presence sharing',
                      body:
                          'Station location tracking is off by default and can only be enabled in your profile after sign-in. When enabled, JomNaik sends only a station or stop ID and time after you are confirmed near it. It does not send your account ID, device ID or raw GPS coordinates with that record. These anonymous presence records are retained for 24 hours, then deleted.',
                    ),
                    const _PrivacySection(
                      title: 'Accounts and reports',
                      body:
                          'If you create an account, email address and sign-in information are handled by Supabase Auth. Incident reports contain the stop, report type, route where relevant and time; do not include personal information in a report. Anonymous incident reports are retained for 30 days, then deleted.',
                    ),
                    const _PrivacySection(
                      title: 'Service providers',
                      body:
                          'Routing and operational data are processed by the JomNaik backend on Databricks. Weather requests use Open-Meteo, and traffic requests use TomTom when traffic information is shown. Opening an e-hailing app takes you to that provider, whose privacy terms apply separately.',
                    ),
                    const _PrivacySection(
                      title: 'Your choices',
                      body:
                          'You can deny or revoke location permission in your device settings, keep station location tracking off, sign out, or stop using the app at any time. For account-data questions or deletion requests, contact the JomNaik beta team through the feedback channel supplied with your test invitation.',
                    ),
                    const _PrivacySection(
                      title: 'Beta notice',
                      body:
                          'JomNaik provides travel-planning guidance only. It does not guarantee live arrivals, fares, e-hailing availability or service conditions. This policy may be updated before a public release; you will be asked to review a new version in the app.',
                    ),
                  ],
                ),
              ),
            ),
            CheckboxListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              controlAffinity: ListTileControlAffinity.leading,
              value: _accepted,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _accepted = value ?? false),
              title: const Text('I have read and accept this Privacy Policy.'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _accepted && !_saving ? _acceptAndContinue : null,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue to JomNaik'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 5),
        Text(body),
      ],
    ),
  );
}
