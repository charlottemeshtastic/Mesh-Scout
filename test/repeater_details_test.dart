import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/nodes/repeater_details.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';

void main() {
  test('repeater information stays keyed by the full public key after reload',() async {
    final root=await Directory.systemTemp.createTemp('scout-repeater-info');
    final container=ProviderContainer(overrides:[dataDirectoryProvider.overrideWithValue(() async => root.path)]);
    try {
      await container.read(repeaterDetailsProvider.future);
      final a='a'*64,b='${'a'*63}b';
      await container.read(repeaterDetailsProvider.notifier).save({'key':a,'site':'First site','hardware':'Test radio'});
      await container.read(repeaterDetailsProvider.notifier).save({'key':b,'site':'Second site'});
      container.invalidate(repeaterDetailsProvider);
      final rows=await container.read(repeaterDetailsProvider.future);
      expect(rows.length,2);expect(rows.singleWhere((r) => r['key']==a)['site'],'First site');
      expect(rows.singleWhere((r) => r['key']==b)['site'],'Second site');
    } finally {container.dispose();await root.delete(recursive:true);}
  });
  test('repeater data rejects secrets, invalid keys and oversized values',() {
    final key='a'*64;
    expect(() => validateRepeaterDetails({'key':key,'password':'secret'}),throwsFormatException);
    expect(() => validateRepeaterDetails({'key':'abcd'}),throwsFormatException);
    expect(() => validateRepeaterDetails({'key':key,'power':'x'*41}),throwsFormatException);
  });
}
