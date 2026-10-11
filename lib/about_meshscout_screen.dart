import 'package:flutter/material.dart';

class AboutMeshScoutScreen extends StatelessWidget {
  const AboutMeshScoutScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('About MeshScout')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: const [
            Text('MeshScout', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('Explore the Mesh. Understand the Signal.'),
            SizedBox(height: 20),
            Text('MeshScout is an independent, Android-first application for observing MeshCore companion-radio reception activity. Coverage mapping and GPS-tagged observations are planned, not yet available.'),
            SizedBox(height: 24),
            Text('Project origins & acknowledgments', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('MeshScout acknowledges the open-source MeshMapper project and its contributors, including the Greater Ottawa Mesh Radio Enthusiasts community. MeshMapper Flutter App: github.com/MeshMapper/MeshMapper_Flutter_App. The upstream project is distributed under the MIT License. See the repository THIRD_PARTY_NOTICES.md for attribution and licensing details.'),
            SizedBox(height: 24),
            Text('Independent project', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('MeshScout is independently developed and is not affiliated with, endorsed by, or sponsored by MeshMapper or MeshCore. Third-party names and trademarks belong to their respective owners.'),
            SizedBox(height: 24),
            Text('Safety & limitations', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('MeshScout is early-stage software. Reception data is informational and does not guarantee message delivery or emergency communications coverage. Do not rely on it as your sole emergency communications tool.'),
            SizedBox(height: 24),
            Text('Open-source licenses', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('Original authors retain their copyrights. Applicable third-party licenses and required notices must be preserved when redistributing their code.'),
            SizedBox(height: 8),
            Text('See licenses for bundled Flutter packages below.'),
            SizedBox(height: 8),
            _LicensesButton(),
          ],
        ),
      );
}

class _LicensesButton extends StatelessWidget {
  const _LicensesButton();

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: () => showLicensePage(
          context: context,
          applicationName: 'MeshScout',
        ),
        child: const Text('View open-source licenses'),
      );
}
