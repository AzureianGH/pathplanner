import 'package:flutter/material.dart';
import 'package:pathplanner/path/field_constraints_profile.dart';
import 'package:pathplanner/widgets/app_settings.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/robot_config_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsDialog extends StatefulWidget {
  final VoidCallback onSettingsChanged;
  final ValueChanged<FieldImage> onFieldSelected;
  final List<FieldImage> fieldImages;
  final FieldImage selectedField;
  final FieldConstraintsProfile fieldProfile;
  final List<String> fieldSetupNames;
  final String selectedFieldSetupName;
  final List<String> hiddenFieldZoneNames;
  final SharedPreferences prefs;
  final ValueChanged<Color> onTeamColorChanged;
  final ValueChanged<FieldConstraintsProfile> onFieldProfileChanged;
  final ValueChanged<String> onSelectedFieldSetupChanged;
  final Future<void> Function() onManageFieldSetups;
  final ValueChanged<List<String>> onHiddenFieldZonesChanged;
  final Future<void> Function() onImportFieldProfile;
  final Future<void> Function() onExportFieldProfile;

  const SettingsDialog({
    required this.onSettingsChanged,
    required this.onFieldSelected,
    required this.fieldImages,
    required this.selectedField,
    required this.fieldProfile,
    required this.fieldSetupNames,
    required this.selectedFieldSetupName,
    required this.hiddenFieldZoneNames,
    required this.prefs,
    required this.onTeamColorChanged,
    required this.onFieldProfileChanged,
    required this.onSelectedFieldSetupChanged,
    required this.onManageFieldSetups,
    required this.onHiddenFieldZonesChanged,
    required this.onImportFieldProfile,
    required this.onExportFieldProfile,
    super.key,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  String _query = '';

  static const List<String> _robotKeywords = [
    'robot',
    'drive',
    'wheel',
    'module',
    'mass',
    'moi',
    'bumper',
    'cof',
    'gear',
    'motor',
    'trackwidth',
  ];

  static const List<String> _appKeywords = [
    'app',
    'about',
    'nathan',
    '3641',
    'frc',
    'field',
    'theme',
    'telemetry',
    'hot reload',
    'color',
    'grid',
    'sort',
    'view',
    'shortcut',
    'rounded',
    'corners',
  ];

  bool _matchesKeywords(List<String> keywords) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }

    return keywords.any((keyword) => keyword.contains(query));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool showRobot = _matchesKeywords(_robotKeywords);
    final bool showApp = _matchesKeywords(_appKeywords);
    final bool hasQuery = _query.trim().isNotEmpty;

    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
        title: const TabBar(
          tabs: [
            Tab(text: 'Robot Config'),
            Tab(text: 'App Settings'),
          ],
        ),
        content: SizedBox(
          width: 820,
          height: 470,
          child: Column(
            children: [
              TextField(
                onChanged: (value) {
                  setState(() {
                    _query = value;
                  });
                },
                decoration: const InputDecoration(
                  hintText: 'Search settings sections...',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: hasQuery
                    ? _buildFilteredContent(showRobot: showRobot, showApp: showApp)
                    : TabBarView(
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          RobotConfigSettings(
                            onSettingsChanged: widget.onSettingsChanged,
                            prefs: widget.prefs,
                          ),
                          AppSettings(
                            onSettingsChanged: widget.onSettingsChanged,
                            onFieldSelected: widget.onFieldSelected,
                            fieldImages: widget.fieldImages,
                            selectedField: widget.selectedField,
                            fieldProfile: widget.fieldProfile,
                            fieldSetupNames: widget.fieldSetupNames,
                            selectedFieldSetupName:
                              widget.selectedFieldSetupName,
                            hiddenFieldZoneNames: widget.hiddenFieldZoneNames,
                            prefs: widget.prefs,
                            onTeamColorChanged: widget.onTeamColorChanged,
                            onFieldProfileChanged: widget.onFieldProfileChanged,
                            onSelectedFieldSetupChanged:
                              widget.onSelectedFieldSetupChanged,
                            onManageFieldSetups: widget.onManageFieldSetups,
                            onHiddenFieldZonesChanged:
                                widget.onHiddenFieldZonesChanged,
                            onImportFieldProfile: widget.onImportFieldProfile,
                            onExportFieldProfile: widget.onExportFieldProfile,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilteredContent({
    required bool showRobot,
    required bool showApp,
  }) {
    if (!showRobot && !showApp) {
      return const Center(
        child: Text('No matching settings sections'),
      );
    }

    return ListView(
      children: [
        if (showRobot)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                height: 340,
                child: RobotConfigSettings(
                  onSettingsChanged: widget.onSettingsChanged,
                  prefs: widget.prefs,
                ),
              ),
            ),
          ),
        if (showApp)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                height: 340,
                child: AppSettings(
                  onSettingsChanged: widget.onSettingsChanged,
                  onFieldSelected: widget.onFieldSelected,
                  fieldImages: widget.fieldImages,
                  selectedField: widget.selectedField,
                  fieldProfile: widget.fieldProfile,
                    fieldSetupNames: widget.fieldSetupNames,
                    selectedFieldSetupName: widget.selectedFieldSetupName,
                  hiddenFieldZoneNames: widget.hiddenFieldZoneNames,
                  prefs: widget.prefs,
                  onTeamColorChanged: widget.onTeamColorChanged,
                  onFieldProfileChanged: widget.onFieldProfileChanged,
                    onSelectedFieldSetupChanged:
                      widget.onSelectedFieldSetupChanged,
                    onManageFieldSetups: widget.onManageFieldSetups,
                  onHiddenFieldZonesChanged:
                      widget.onHiddenFieldZonesChanged,
                  onImportFieldProfile: widget.onImportFieldProfile,
                  onExportFieldProfile: widget.onExportFieldProfile,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
