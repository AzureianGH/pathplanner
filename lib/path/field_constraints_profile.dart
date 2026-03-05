import 'dart:convert';

import 'package:file/file.dart';
import 'package:path/path.dart';
import 'package:pathplanner/path/optimization_boundary.dart';

const String fieldProfileFileVersion = '2026.0';
const String fieldProfileDefaultFileName = 'field.ppx';
const String fieldProfileSetupsDirName = 'field_setups';
const String defaultFieldSetupName = 'default';

class FieldConstraintObject {
  String name;
  OptimizationBoundary boundary;

  FieldConstraintObject({
    required this.name,
    required this.boundary,
  });

  factory FieldConstraintObject.fromJson(Map<String, dynamic> json) {
    return FieldConstraintObject(
      name: (json['name'] ?? 'Object').toString(),
      boundary: OptimizationBoundary.fromJson(json['boundary'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'boundary': boundary.toJson(),
    };
  }

  FieldConstraintObject clone() {
    return FieldConstraintObject(
      name: name,
      boundary: boundary.clone(),
    );
  }
}

class FieldConstraintZone {
  String name;
  OptimizationBoundary boundary;
  bool visibleByDefault;

  FieldConstraintZone({
    required this.name,
    required this.boundary,
    this.visibleByDefault = true,
  });

  factory FieldConstraintZone.fromJson(Map<String, dynamic> json) {
    return FieldConstraintZone(
      name: (json['name'] ?? 'Zone').toString(),
      boundary: OptimizationBoundary.fromJson(json['boundary'] ?? {}),
      visibleByDefault: json['visibleByDefault'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'boundary': boundary.toJson(),
      'visibleByDefault': visibleByDefault,
    };
  }

  FieldConstraintZone clone() {
    return FieldConstraintZone(
      name: name,
      boundary: boundary.clone(),
      visibleByDefault: visibleByDefault,
    );
  }
}

class FieldConstraintsProfile {
  String fieldName;
  List<FieldConstraintObject> objects;
  List<FieldConstraintZone> zones;

  FieldConstraintsProfile({
    required this.fieldName,
    required this.objects,
    required this.zones,
  });

  factory FieldConstraintsProfile.empty({String fieldName = ''}) {
    return FieldConstraintsProfile(
      fieldName: fieldName,
      objects: [],
      zones: [],
    );
  }

  factory FieldConstraintsProfile.fromJson(Map<String, dynamic> json) {
    return FieldConstraintsProfile(
      fieldName: (json['fieldName'] ?? '').toString(),
      objects: [
        for (final objectJson in (json['objects'] ?? []))
          FieldConstraintObject.fromJson(objectJson),
      ],
      zones: [
        for (final zoneJson in (json['zones'] ?? []))
          FieldConstraintZone.fromJson(zoneJson),
      ],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': fieldProfileFileVersion,
      'fieldName': fieldName,
      'objects': [
        for (final object in objects) object.toJson(),
      ],
      'zones': [
        for (final zone in zones) zone.toJson(),
      ],
    };
  }

  FieldConstraintsProfile clone() {
    return FieldConstraintsProfile(
      fieldName: fieldName,
      objects: [for (final object in objects) object.clone()],
      zones: [for (final zone in zones) zone.clone()],
    );
  }

  List<OptimizationBoundary> objectBoundaries() {
    return [for (final object in objects) object.boundary.clone()];
  }

  static String sanitizeSetupName(String setupName) {
    var out = setupName.trim();
    if (out.isEmpty) {
      out = defaultFieldSetupName;
    }
    out = out.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    out = out.replaceAll(RegExp(r'\s+'), '_');
    return out;
  }

  static String setupFileName(String setupName) {
    return '${sanitizeSetupName(setupName)}.ppx';
  }

  static String setupFilePath(String pathplannerDir, String setupName) {
    return join(pathplannerDir, fieldProfileSetupsDirName, setupFileName(setupName));
  }

  static Future<List<String>> listSetupNames(
    String pathplannerDir,
    FileSystem fs,
  ) async {
    final setupsDir = fs.directory(join(pathplannerDir, fieldProfileSetupsDirName));
    final names = <String>{};

    if (await setupsDir.exists()) {
      await for (final entity in setupsDir.list()) {
        if (entity is! File) continue;
        final base = basename(entity.path);
        if (!base.toLowerCase().endsWith('.ppx')) continue;
        names.add(basenameWithoutExtension(base));
      }
    }

    final legacyFile = fs.file(join(pathplannerDir, fieldProfileDefaultFileName));
    if (await legacyFile.exists()) {
      names.add(defaultFieldSetupName);
    }

    final out = names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  static Future<FieldConstraintsProfile> loadSetupFromProjectDir(
    String pathplannerDir,
    FileSystem fs, {
    required String setupName,
    String fallbackFieldName = '',
  }) async {
    final profile = await loadSetupFromFile(pathplannerDir, fs, setupName);
    return profile ?? FieldConstraintsProfile.empty(fieldName: fallbackFieldName);
  }

  static Future<FieldConstraintsProfile?> loadSetupFromFile(
    String pathplannerDir,
    FileSystem fs,
    String setupName,
  ) async {
    final setupPath = setupFilePath(pathplannerDir, setupName);
    final setupFile = fs.file(setupPath);
    if (await setupFile.exists()) {
      return loadFromFilePath(setupPath, fs);
    }

    if (sanitizeSetupName(setupName) == defaultFieldSetupName) {
      final legacyPath = join(pathplannerDir, fieldProfileDefaultFileName);
      final legacyFile = fs.file(legacyPath);
      if (await legacyFile.exists()) {
        return loadFromFilePath(legacyPath, fs);
      }
    }

    return null;
  }

  Future<void> saveSetupToProjectDir(
    String pathplannerDir,
    FileSystem fs, {
    required String setupName,
  }) async {
    final filePath = setupFilePath(pathplannerDir, setupName);
    await saveToFilePath(filePath, fs);
  }

  static Future<void> deleteSetupFromProjectDir(
    String pathplannerDir,
    FileSystem fs, {
    required String setupName,
  }) async {
    final file = fs.file(setupFilePath(pathplannerDir, setupName));
    if (await file.exists()) {
      await file.delete();
    }
  }

  static Future<String?> renameSetupInProjectDir(
    String pathplannerDir,
    FileSystem fs, {
    required String oldSetupName,
    required String newSetupName,
  }) async {
    final oldName = sanitizeSetupName(oldSetupName);
    final newName = sanitizeSetupName(newSetupName);
    if (newName.isEmpty || oldName == newName) {
      return null;
    }

    final oldPath = setupFilePath(pathplannerDir, oldName);
    final newPath = setupFilePath(pathplannerDir, newName);

    final oldFile = fs.file(oldPath);
    if (!await oldFile.exists()) {
      return null;
    }

    final newFile = fs.file(newPath);
    if (await newFile.exists()) {
      return null;
    }

    await oldFile.rename(newPath);
    return newName;
  }

  static Future<String?> importSetupToProjectDir(
    String pathplannerDir,
    FileSystem fs, {
    required String importPath,
    String? setupName,
  }) async {
    final imported = await loadFromFilePath(importPath, fs);
    if (imported == null) {
      return null;
    }

    final baseName = sanitizeSetupName(
      setupName ?? basenameWithoutExtension(importPath),
    );

    String candidate = baseName;
    int counter = 2;
    while (await fs.file(setupFilePath(pathplannerDir, candidate)).exists()) {
      candidate = '${baseName}_$counter';
      counter++;
    }

    await imported.saveSetupToProjectDir(pathplannerDir, fs, setupName: candidate);
    return candidate;
  }

  static Future<void> exportSetupFromProjectDir(
    String pathplannerDir,
    FileSystem fs, {
    required String setupName,
    required String exportPath,
  }) async {
    final profile = await loadSetupFromFile(pathplannerDir, fs, setupName);
    if (profile == null) {
      return;
    }

    await profile.saveToFilePath(exportPath, fs);
  }

  static Future<FieldConstraintsProfile> loadFromProjectDir(
    String pathplannerDir,
    FileSystem fs, {
    String fallbackFieldName = '',
  }) async {
    return loadSetupFromProjectDir(
      pathplannerDir,
      fs,
      setupName: defaultFieldSetupName,
      fallbackFieldName: fallbackFieldName,
    );
  }

  static Future<FieldConstraintsProfile?> loadFromFilePath(
    String filePath,
    FileSystem fs,
  ) async {
    final file = fs.file(filePath);
    if (!await file.exists()) {
      return null;
    }

    final jsonStr = await file.readAsString();
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    return FieldConstraintsProfile.fromJson(json);
  }

  Future<void> saveToProjectDir(String pathplannerDir, FileSystem fs) {
    return saveSetupToProjectDir(
      pathplannerDir,
      fs,
      setupName: defaultFieldSetupName,
    );
  }

  Future<void> saveToFilePath(String filePath, FileSystem fs) async {
    final file = fs.file(filePath);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }

    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(toJson()));
  }
}
