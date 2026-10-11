import 'package:flutter/material.dart';

class AboutMeshScoutScreen extends StatelessWidget {
  const AboutMeshScoutScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('About MeshScout')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: const [
            Text(
              'MeshScout',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('Explore the Mesh. Understand the Signal.'),
            SizedBox(height: 20),
            Text(
              'MeshScout is an independent Android application for observing '
              'MeshCore radio activity, recording field measurements and '
              'exploring measured coverage. Field hardware validation remains '
              'necessary.',
            ),
            SizedBox(height: 24),
            Text(
              'Project origins and acknowledgments',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'MeshScout acknowledges the open-source MeshMapper project and '
              'its contributors, including the Greater Ottawa Mesh Radio '
              'Enthusiasts community. The upstream MeshMapper Flutter App is '
              'published under the MIT License. See THIRD_PARTY_NOTICES.md '
              'in the MeshScout repository for licensing details and the '
              'original project link.',
            ),
            SizedBox(height: 24),
            Text(
              'Independent project',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'MeshScout is independently developed and is not affiliated '
              'with, sponsored by or endorsed by MeshMapper or MeshCore. '
              'Third-party trademarks remain with their owners.',
            ),
            SizedBox(height: 24),
            Text(
              'Safety and limitations',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Reception data and mapped observations do not guarantee '
              'message delivery or emergency communications coverage. '
              'Do not rely on MeshScout as your sole emergency tool.',
            ),
            SizedBox(height: 24),
            Text(
              'Open-source licenses',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Original authors retain their copyrights. Applicable '
              'third-party license notices must accompany redistributed code.',
            ),
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
