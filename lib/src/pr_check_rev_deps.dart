part of 'pr_check.dart';

/// Callback that returns candidate reverse-dependency package names for
/// [packageName] when `--rev-deps` is enabled.
typedef ReverseDepNamesLookup = List<String> Function(String packageName);

/// Returns the target stable release [Version] if [currentVer] is within the
/// caret compatibility range of [baseVerStr] (`^baseVer`), or `null` if
/// [currentVer] is a major (or `0.y.z`-breaking) version bump.
Version? nonMajorTargetReleaseVersion(Version? currentVer, String? baseVerStr) {
  if (currentVer == null || baseVerStr == null) return null;
  try {
    final baseVer = Version.parse(baseVerStr);
    final baseRelease = Version(baseVer.major, baseVer.minor, baseVer.patch);
    final targetRelease = Version(
      currentVer.major,
      currentVer.minor,
      currentVer.patch,
    );
    if (!VersionConstraint.compatibleWith(baseRelease).allows(targetRelease)) {
      return null;
    }
    return targetRelease;
  } on FormatException {
    return null;
  }
}

/// Returns `true` if `pubspec.yaml` content [pubspecYaml] declares a direct
/// `dependencies:` entry on [dependencyName] whose constraint allows
/// [targetReleaseVersion].
bool pubspecContentAllowsDependencyVersion(
  String pubspecYaml,
  String dependencyName,
  Version targetReleaseVersion,
) {
  try {
    final doc = loadYaml(pubspecYaml);
    if (doc is! YamlMap) return false;
    final deps = doc['dependencies'];
    if (deps is! YamlMap || !deps.containsKey(dependencyName)) return false;
    final rawConstraint = deps[dependencyName];
    if (rawConstraint == null) return true;
    if (rawConstraint is! String) return false;
    return VersionConstraint.parse(rawConstraint).allows(targetReleaseVersion);
  } on Object {
    return false;
  }
}

/// Prepares an unpacked downstream package directory [unpackedDir] for
/// standalone `dart pub get` and `dart analyze lib` against
/// [localDependencyPath].
///
/// Removes `analysis_options.yaml` (so consumer lints do not fail the check),
/// strips `resolution`, `workspace`, `dev_dependencies`, and
/// `dependency_overrides` from `pubspec.yaml`, and writes
/// `pubspec_overrides.yaml` pointing [dependencyName] to [localDependencyPath].
void prepareUnpackedConsumerForAnalysis({
  required Directory unpackedDir,
  required String dependencyName,
  required String localDependencyPath,
}) {
  final analysisOptions = File(
    p.join(unpackedDir.path, 'analysis_options.yaml'),
  );
  if (analysisOptions.existsSync()) {
    analysisOptions.deleteSync();
  }

  final pubspecFile = File(p.join(unpackedDir.path, 'pubspec.yaml'));
  if (pubspecFile.existsSync()) {
    final raw = pubspecFile.readAsStringSync();
    final doc = loadYaml(raw);
    if (doc is YamlMap) {
      final editor = YamlEditor(raw);
      for (final key in const [
        'resolution',
        'workspace',
        'dev_dependencies',
        'dependency_overrides',
      ]) {
        if (doc.containsKey(key)) {
          editor.remove([key]);
        }
      }
      pubspecFile.writeAsStringSync(editor.toString());
    }
  }

  final overridesFile = File(
    p.join(unpackedDir.path, 'pubspec_overrides.yaml'),
  );
  final escapedPath = jsonEncode(localDependencyPath);
  overridesFile.writeAsStringSync(
    'dependency_overrides:\n'
    '  $dependencyName:\n'
    '    path: $escapedPath\n',
  );
}

/// Unpacks each candidate consumer in [candidateConsumerNames] via
/// `dart pub unpack --no-resolve`, overrides [pkg] to its local path, and runs
/// `dart pub get` + `dart analyze lib`.
List<PrCheckViolation> checkPackageReverseDepsWithPubUnpack({
  required firehose.Package pkg,
  required Version targetRelease,
  required List<String> candidateConsumerNames,
  required String dartBin,
  required SyncProcessRunner runSync,
}) {
  if (candidateConsumerNames.isEmpty) return const [];
  final tempDir = Directory.systemTemp.createTempSync('pr_check_rev_deps_');
  try {
    final violations = <PrCheckViolation>[];
    for (final consumerName in candidateConsumerNames) {
      if (consumerName == pkg.name) continue;
      final violation = _unpackAndAnalyzeSingleConsumer(
        pkg: pkg,
        targetRelease: targetRelease,
        consumerName: consumerName,
        tempDir: tempDir,
        dartBin: dartBin,
        runSync: runSync,
      );
      if (violation != null) violations.add(violation);
    }
    return violations;
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

PrCheckViolation? _unpackAndAnalyzeSingleConsumer({
  required firehose.Package pkg,
  required Version targetRelease,
  required String consumerName,
  required Directory tempDir,
  required String dartBin,
  required SyncProcessRunner runSync,
}) {
  final unpackRes = runSync(dartBin, [
    'pub',
    'unpack',
    consumerName,
    '--no-resolve',
    '--output=${tempDir.path}',
  ], workingDirectory: tempDir.path);
  if (unpackRes.exitCode != 0) return null;

  final unpackedDir = _findUnpackedConsumerDir(tempDir, consumerName);
  if (unpackedDir == null) return null;

  final pubspecFile = File(p.join(unpackedDir.path, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) return null;
  if (!pubspecContentAllowsDependencyVersion(
    pubspecFile.readAsStringSync(),
    pkg.name,
    targetRelease,
  )) {
    return null;
  }

  final libDir = Directory(p.join(unpackedDir.path, 'lib'));
  if (!libDir.existsSync()) return null;

  prepareUnpackedConsumerForAnalysis(
    unpackedDir: unpackedDir,
    dependencyName: pkg.name,
    localDependencyPath: pkg.directory.path,
  );

  final pubGetRes = runSync(dartBin, [
    'pub',
    'get',
  ], workingDirectory: unpackedDir.path);
  if (pubGetRes.exitCode != 0) return null;

  final analyzeRes = runSync(dartBin, [
    'analyze',
    'lib',
  ], workingDirectory: unpackedDir.path);
  if (analyzeRes.exitCode == 0) return null;

  final consumerLabel = p.basename(unpackedDir.path);
  final rawOut = '${analyzeRes.stdout}\n${analyzeRes.stderr}'.trim();
  final errorLines = const LineSplitter()
      .convert(rawOut)
      .where((line) => line.trimLeft().startsWith('error -'))
      .toList();
  final summary = errorLines.isNotEmpty ? errorLines.join('\n') : rawOut;

  return PrCheckViolation(
    check: 'rev-deps',
    message:
        'Published reverse dependency $consumerLabel failed '
        '`dart analyze lib` against local package:${pkg.name} '
        '($targetRelease):\n$summary',
    remediation:
        'Export newly added symbol(s) from a dedicated sub-library '
        'entrypoint, rename colliding symbol(s), bump package:${pkg.name} to '
        'a major version, or publish a compatible $consumerName update first.',
  );
}

Directory? _findUnpackedConsumerDir(Directory tempDir, String consumerName) {
  final prefix = '$consumerName-';
  for (final entity in tempDir.listSync().whereType<Directory>()) {
    if (p.basename(entity.path).startsWith(prefix)) {
      return entity;
    }
  }
  return null;
}

/// Discovers candidate reverse-dependency package names for [packageName] by
/// querying `pub.dev` search and scanning `~/.pub-cache/hosted/pub.dev`.
Future<List<String>> fetchCandidateReverseDepNames(
  String packageName, {
  Version? targetReleaseVersion,
  Directory? pubCacheHostedDir,
  Duration timeout = const Duration(seconds: 3),
  int maxPubDevPackages = 10,
}) async {
  final names = <String>{};
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final generalNames = await _searchPubDevDependencyNames(
      client,
      query: 'dependency:$packageName',
      timeout: timeout,
    );
    names.addAll(generalNames.take(maxPubDevPackages));

    final kevmooNames = await _searchPubDevDependencyNames(
      client,
      query: 'dependency:$packageName publisher:kevmoo.com',
      timeout: timeout,
    );
    names.addAll(kevmooNames);
  } on Object {
    // Fall back to local pub-cache discovery on network error.
  } finally {
    client.close(force: true);
  }

  names
    ..addAll(
      discoverPubCacheReverseDepNames(
        packageName,
        targetReleaseVersion: targetReleaseVersion,
        pubCacheHostedDir: pubCacheHostedDir,
      ),
    )
    ..remove(packageName);
  return names.toList();
}

Future<List<String>> _searchPubDevDependencyNames(
  HttpClient client, {
  required String query,
  required Duration timeout,
}) async {
  final uri = Uri.https('pub.dev', '/api/search', {'q': query});
  final req = await client.getUrl(uri).timeout(timeout);
  final resp = await req.close().timeout(timeout);
  if (resp.statusCode != HttpStatus.ok) return const [];
  final body = await resp.transform(utf8.decoder).join().timeout(timeout);
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, Object?>) return const [];
  final packages = decoded['packages'];
  if (packages is! List) return const [];
  return packages
      .whereType<Map<String, Object?>>()
      .map((m) => m['package'])
      .whereType<String>()
      .toList();
}

/// Scans `~/.pub-cache/hosted/pub.dev` for cached packages whose latest stable
/// `pubspec.yaml` depends on [packageName].
List<String> discoverPubCacheReverseDepNames(
  String packageName, {
  Version? targetReleaseVersion,
  Directory? pubCacheHostedDir,
}) {
  final hostedDir = pubCacheHostedDir ?? _defaultPubCacheHostedDir();
  if (hostedDir == null || !hostedDir.existsSync()) return const [];

  final latestByPkg = _latestStablePubCacheDirs(hostedDir, packageName);
  final matching = <String>[];
  for (final MapEntry(key: name, value: (_, dir)) in latestByPkg.entries) {
    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) continue;
    final content = pubspecFile.readAsStringSync();
    if (_pubspecMatchesDependency(content, packageName, targetReleaseVersion)) {
      matching.add(name);
    }
  }
  return matching..sort();
}

Map<String, (Version, Directory)> _latestStablePubCacheDirs(
  Directory hostedDir,
  String excludedPackage,
) {
  final latestByPkg = <String, (Version, Directory)>{};
  for (final entity in hostedDir.listSync().whereType<Directory>()) {
    final parsed = _parsePubCacheDirName(p.basename(entity.path));
    if (parsed == null) continue;
    final (name, ver) = parsed;
    if (name == excludedPackage) continue;
    final prev = latestByPkg[name];
    if (prev == null || ver > prev.$1) {
      latestByPkg[name] = (ver, entity);
    }
  }
  return latestByPkg;
}

bool _pubspecMatchesDependency(
  String pubspecYaml,
  String dependencyName,
  Version? targetReleaseVersion,
) => targetReleaseVersion != null
    ? pubspecContentAllowsDependencyVersion(
        pubspecYaml,
        dependencyName,
        targetReleaseVersion,
      )
    : _pubspecDeclaresDirectDependency(pubspecYaml, dependencyName);

(String, Version)? _parsePubCacheDirName(String baseName) {
  final dashIdx = baseName.indexOf('-');
  if (dashIdx <= 0 || dashIdx + 1 >= baseName.length) return null;
  final name = baseName.substring(0, dashIdx);
  final rawVer = baseName.substring(dashIdx + 1);
  try {
    final ver = Version.parse(rawVer);
    return ver.isPreRelease ? null : (name, ver);
  } on FormatException {
    return null;
  }
}

bool _pubspecDeclaresDirectDependency(
  String pubspecYaml,
  String dependencyName,
) {
  try {
    final doc = loadYaml(pubspecYaml);
    if (doc is! YamlMap) return false;
    final deps = doc['dependencies'];
    return deps is YamlMap && deps.containsKey(dependencyName);
  } on Object {
    return false;
  }
}

Directory? _defaultPubCacheHostedDir() {
  final pubCache =
      Platform.environment['PUB_CACHE'] ??
      (Platform.environment['HOME'] != null
          ? p.join(Platform.environment['HOME']!, '.pub-cache')
          : null);
  if (pubCache == null) return null;
  return Directory(p.join(pubCache, 'hosted', 'pub.dev'));
}

Future<ReverseDepNamesLookup?> _buildCliReverseDepNamesLookup({
  required Directory directory,
  required String? baseRefOverride,
  required bool runRevDeps,
  required SyncProcessRunner processRunner,
}) async {
  if (!runRevDeps || processRunner != defaultSyncProcessRunner) return null;
  final repoRoot = _resolveGitTopLevel(directory, processRunner) ?? directory;
  final baseRef = _resolveBaseRef(repoRoot, baseRefOverride, processRunner);
  final changedFiles = _collectChangedFiles(repoRoot, baseRef, processRunner);
  if (changedFiles.isEmpty) return null;

  final packages = runZoned(
    () => firehose.Repository(repoRoot).locatePackages(),
    zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
  );
  final changedSet = changedFiles.toSet();
  final namesByPkg = <String, List<String>>{};

  for (final pkg in packages) {
    final relDir = p.relative(pkg.directory.path, from: repoRoot.path);
    final prefix = relDir == '.' ? '' : '$relDir/';
    final pkgChanged = _packageRelativeChanges(prefix, changedSet);
    if (!pkgChanged.any((f) => f.startsWith('lib/')) || pkg.version == null) {
      continue;
    }
    final baseVer = _readBasePubspecVersion(
      repoRoot,
      baseRef,
      '${prefix}pubspec.yaml',
      processRunner,
    );
    final targetRelease = nonMajorTargetReleaseVersion(pkg.version, baseVer);
    if (targetRelease == null) continue;
    namesByPkg[pkg.name] = await fetchCandidateReverseDepNames(
      pkg.name,
      targetReleaseVersion: targetRelease,
    );
  }

  return (String pkgName) =>
      namesByPkg[pkgName] ?? discoverPubCacheReverseDepNames(pkgName);
}

void _runPackageRevDepChecks({
  required _PrCheckRunner runner,
  required firehose.Package pkg,
  required List<String> pkgChanged,
  required String? baseVerStr,
  required bool runRevDeps,
}) {
  if (!pkgChanged.any((f) => f.startsWith('lib/'))) return;
  final targetRelease = nonMajorTargetReleaseVersion(pkg.version, baseVerStr);
  if (targetRelease == null) return;

  final label = 'rev-deps:${pkg.name}';
  if (!runRevDeps) {
    runner._skip(label, 'pass --rev-deps to run');
    return;
  }

  final candidateNames =
      runner.reverseDepNamesLookup?.call(pkg.name) ??
      discoverPubCacheReverseDepNames(
        pkg.name,
        targetReleaseVersion: targetRelease,
      );
  final found = checkPackageReverseDepsWithPubUnpack(
    pkg: pkg,
    targetRelease: targetRelease,
    candidateConsumerNames: candidateNames,
    dartBin: runner.dartBin,
    runSync: runner.runSync,
  );
  runner._recordMulti(label, found);
}
