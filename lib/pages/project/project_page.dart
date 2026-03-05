import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:file/file.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:path/path.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/named_command.dart';
import 'package:pathplanner/pages/auto_editor_page.dart';
import 'package:pathplanner/pages/choreo_path_editor_page.dart';
import 'package:pathplanner/pages/path_editor_page.dart';
import 'package:pathplanner/pages/project/project_item_card.dart';
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/path/field_constraints_profile.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/path/event_marker.dart';
import 'package:pathplanner/path/path_constraints.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/services/pplib_telemetry.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/widgets/conditional_widget.dart';
import 'package:pathplanner/widgets/dialogs/management_dialog.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/renamable_title.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';
import 'package:watcher/watcher.dart';

class ProjectPage extends StatefulWidget {
  static Set<String> events = {};

  final SharedPreferences prefs;
  final FieldImage fieldImage;
  final FieldConstraintsProfile? fieldProfile;
  final List<String>? hiddenFieldZoneNames;
  final Directory pathplannerDirectory;
  final Directory choreoDirectory;
  final FileSystem fs;
  final ChangeStack undoStack;
  final bool shortcuts;
  final PPLibTelemetry? telemetry;
  final bool hotReload;
  final VoidCallback? onFoldersChanged;
  final List<String>? fieldSetupNames;
  final String? selectedFieldSetupName;
  final ValueChanged<String>? onFieldSetupSelected;
  final VoidCallback? onManageFieldSetups;
  final bool simulatePath;
  final bool watchChorDir;

  // Stupid workaround to get when settings are updated
  static bool settingsUpdated = false;

  const ProjectPage({
    super.key,
    required this.prefs,
    required this.fieldImage,
    this.fieldProfile,
    this.hiddenFieldZoneNames,
    required this.pathplannerDirectory,
    required this.choreoDirectory,
    required this.fs,
    required this.undoStack,
    this.shortcuts = true,
    this.telemetry,
    this.hotReload = false,
    this.onFoldersChanged,
    this.fieldSetupNames,
    this.selectedFieldSetupName,
    this.onFieldSetupSelected,
    this.onManageFieldSetups,
    this.simulatePath = false,
    this.watchChorDir = false,
  });

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

enum ProjectMenuSection { paths, autos }

enum _PackageConflictAction { overwrite, makeCopy, cancel }

class _ProjectPageState extends State<ProjectPage> {
  final MultiSplitViewController _controller = MultiSplitViewController();
  ProjectMenuSection _activeSection = ProjectMenuSection.paths;
  String _layoutMode = Defaults.projectLayoutMode;
  List<PathPlannerPath> _paths = [];
  List<String> _pathFolders = [];
  List<PathPlannerAuto> _autos = [];
  List<String> _autoFolders = [];
  List<ChoreoPath> _choreoPaths = [];
  late Directory _pathsDirectory;
  late Directory _autosDirectory;
  late Directory _choreoDirectory;
  late String _pathSortValue;
  late String _autoSortValue;
  late bool _pathsCompact;
  late bool _autosCompact;
  late int _pathGridCount;
  late int _autosGridCount;
  DirectoryWatcher? _chorWatcher;
  StreamSubscription<WatchEvent>? _chorWatcherSub;

  String _pathSearchQuery = '';
  String _autoSearchQuery = '';

  late TextEditingController _pathSearchController;
  late TextEditingController _autoSearchController;

  bool _loading = true;

  bool _quickLayoutExpanded = true;
  bool _quickFolderExpanded = true;
  bool _quickViewExpanded = true;
  bool _quickCreateExpanded = true;
  bool _quickManageExpanded = true;

  String? _pathFolder;
  String? _autoFolder;
  bool _inChoreoFolder = false;

  final List<String> _pathBackStack = [];
  final List<String> _pathForwardStack = [];
  final List<String?> _autoBackStack = [];
  final List<String?> _autoForwardStack = [];

  final GlobalKey _addAutoKey = GlobalKey();

  FileSystem get fs => widget.fs;

  @override
  void initState() {
    super.initState();

    _pathSearchController = TextEditingController();
    _autoSearchController = TextEditingController();

    _layoutMode = widget.prefs.getString(PrefsKeys.projectLayoutMode) ??
        Defaults.projectLayoutMode;

    double leftWeight = widget.prefs.getDouble(PrefsKeys.projectLeftWeight) ??
        Defaults.projectLeftWeight;
    _controller.areas = [
      Area(
        weight: leftWeight,
        minimalWeight: 0.33,
      ),
      Area(
        weight: 1.0 - leftWeight,
        minimalWeight: 0.33,
      ),
    ];

    _pathSortValue = widget.prefs.getString(PrefsKeys.pathSortOption) ??
        Defaults.pathSortOption;
    _autoSortValue = widget.prefs.getString(PrefsKeys.autoSortOption) ??
        Defaults.autoSortOption;
    _pathsCompact = widget.prefs.getBool(PrefsKeys.pathsCompactView) ??
        Defaults.pathsCompactView;
    _autosCompact = widget.prefs.getBool(PrefsKeys.autosCompactView) ??
        Defaults.autosCompactView;

    _pathGridCount = _getCrossAxisCountForWeight(leftWeight);
    _autosGridCount = _getCrossAxisCountForWeight(1.0 - leftWeight);

    _pathFolders = widget.prefs.getStringList(PrefsKeys.pathFolders) ??
        Defaults.pathFolders;
    _autoFolders = widget.prefs.getStringList(PrefsKeys.autoFolders) ??
        Defaults.autoFolders;
    _addMissingParentFolders(_pathFolders);
    _addMissingParentFolders(_autoFolders);

    // Set up choreo directory watcher
    if (widget.watchChorDir) {
      widget.choreoDirectory.exists().then((value) {
        if (value) {
          _chorWatcher = DirectoryWatcher(widget.choreoDirectory.path,
              pollingDelay: const Duration(seconds: 1));

          Timer? loadTimer;

          _chorWatcherSub = _chorWatcher!.events.listen((event) {
            loadTimer?.cancel();
            loadTimer = Timer(const Duration(milliseconds: 500), () {
              _load();
              if (mounted) {
                if (Navigator.of(this.context).canPop()) {
                  // We might have a path or auto open, close it
                  Navigator.of(this.context).pop();
                }

                ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('Reloaded Choreo paths')));
              }
            });
          });
        }
      });
    }

    _load();
  }

  @override
  void dispose() {
    _chorWatcherSub?.cancel();

    _pathSearchController.dispose();
    _autoSearchController.dispose();
    super.dispose();
  }

  String _sanitizeFolderLeaf(String value) {
    return value.trim().replaceAll('/', '-');
  }

  String _currentPathToken() {
    if (_inChoreoFolder) return '__CHOREO__';
    return _pathFolder ?? '__ROOT__';
  }

  void _applyPathToken(String token) {
    if (token == '__CHOREO__') {
      _inChoreoFolder = true;
      _pathFolder = null;
    } else {
      _inChoreoFolder = false;
      _pathFolder = token == '__ROOT__' ? null : token;
    }
  }

  void _navigatePathView({
    String? folder,
    bool inChoreo = false,
    bool recordHistory = true,
    bool clearForward = true,
  }) {
    final newToken = inChoreo ? '__CHOREO__' : (folder ?? '__ROOT__');
    final currentToken = _currentPathToken();
    if (newToken == currentToken) return;

    setState(() {
      if (recordHistory) {
        _pathBackStack.add(currentToken);
      }
      if (clearForward) {
        _pathForwardStack.clear();
      }
      _applyPathToken(newToken);
    });
  }

  void _navigateAutoView({
    String? folder,
    bool recordHistory = true,
    bool clearForward = true,
  }) {
    if (folder == _autoFolder) return;

    setState(() {
      if (recordHistory) {
        _autoBackStack.add(_autoFolder);
      }
      if (clearForward) {
        _autoForwardStack.clear();
      }
      _autoFolder = folder;
    });
  }

  void _goBackFolder({required bool isPathsView}) {
    if (isPathsView) {
      if (_pathBackStack.isEmpty) return;
      final prev = _pathBackStack.removeLast();
      final current = _currentPathToken();
      setState(() {
        _pathForwardStack.add(current);
        _applyPathToken(prev);
      });
    } else {
      if (_autoBackStack.isEmpty) return;
      final prev = _autoBackStack.removeLast();
      final current = _autoFolder;
      setState(() {
        _autoForwardStack.add(current);
        _autoFolder = prev;
      });
    }
  }

  void _goForwardFolder({required bool isPathsView}) {
    if (isPathsView) {
      if (_pathForwardStack.isEmpty) return;
      final next = _pathForwardStack.removeLast();
      final current = _currentPathToken();
      setState(() {
        _pathBackStack.add(current);
        _applyPathToken(next);
      });
    } else {
      if (_autoForwardStack.isEmpty) return;
      final next = _autoForwardStack.removeLast();
      final current = _autoFolder;
      setState(() {
        _autoBackStack.add(current);
        _autoFolder = next;
      });
    }
  }

  void _goUpFolder({required bool isPathsView}) {
    if (isPathsView) {
      if (_inChoreoFolder) {
        _navigatePathView(folder: null, inChoreo: false);
        return;
      }
      _navigatePathView(
        folder: _pathFolder == null ? null : _parentFolder(_pathFolder!),
        inChoreo: false,
      );
    } else {
      _navigateAutoView(
        folder: _autoFolder == null ? null : _parentFolder(_autoFolder!),
      );
    }
  }

  void _goHomeFolder({required bool isPathsView}) {
    if (isPathsView) {
      _navigatePathView(folder: null, inChoreo: false);
    } else {
      _navigateAutoView(folder: null);
    }
  }

  String _joinFolderPath(String? parent, String leaf) {
    return parent == null ? leaf : '$parent/$leaf';
  }

  String? _parentFolder(String folder) {
    final idx = folder.lastIndexOf('/');
    if (idx < 0) return null;
    return folder.substring(0, idx);
  }

  String _folderLeaf(String folder) {
    final idx = folder.lastIndexOf('/');
    if (idx < 0) return folder;
    return folder.substring(idx + 1);
  }

  bool _isInFolderTree(String folder, String rootFolder) {
    return folder == rootFolder || folder.startsWith('$rootFolder/');
  }

  String _replaceFolderPrefix(
      String original, String oldPrefix, String newPrefix) {
    if (original == oldPrefix) return newPrefix;
    return '$newPrefix/${original.substring(oldPrefix.length + 1)}';
  }

  List<String> _childFolders(List<String> folders, String? parent) {
    return folders.where((f) => _parentFolder(f) == parent).toList();
  }

  bool _matchesFolderFilter(
    String? itemFolder,
    String? selectedFolder,
    String query,
  ) {
    if (query.trim().isNotEmpty) {
      return true;
    }
    return itemFolder == selectedFolder;
  }

  String _newUniqueFolderPath(List<String> folders, String? parent) {
    String leaf = 'New Folder';
    while (folders.contains(_joinFolderPath(parent, leaf))) {
      leaf = 'New $leaf';
    }
    return _joinFolderPath(parent, leaf);
  }

  void _addMissingParentFolders(List<String> folders) {
    final toAdd = <String>{};

    for (final folder in folders) {
      String? parent = _parentFolder(folder);
      while (parent != null) {
        if (!folders.contains(parent)) {
          toAdd.add(parent);
        }
        parent = _parentFolder(parent);
      }
    }

    folders.addAll(toAdd);
  }

  void _renameFolderPath({
    required bool isPathsView,
    required String oldPath,
    required String newLeaf,
    required BuildContext context,
  }) {
    final sanitizedLeaf = _sanitizeFolderLeaf(newLeaf);
    if (sanitizedLeaf.isEmpty) return;

    final parent = _parentFolder(oldPath);
    final newPath = _joinFolderPath(parent, sanitizedLeaf);

    if (newPath == oldPath) return;

    final folders = isPathsView ? _pathFolders : _autoFolders;
    if (folders.contains(newPath)) {
      showDialog(
          context: context,
          builder: (BuildContext context) {
            ColorScheme colorScheme = Theme.of(context).colorScheme;
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: const Text('Unable to Rename'),
              content: Text('The folder "$sanitizedLeaf" already exists'),
              actions: [
                TextButton(
                  onPressed: Navigator.of(context).pop,
                  child: const Text('OK'),
                ),
              ],
            );
          });
      return;
    }

    setState(() {
      if (isPathsView) {
        for (final path in _paths) {
          final folder = path.folder;
          if (folder != null && _isInFolderTree(folder, oldPath)) {
            path.folder = _replaceFolderPrefix(folder, oldPath, newPath);
            path.generateAndSavePath();
          }
        }

        for (int i = 0; i < _pathFolders.length; i++) {
          if (_isInFolderTree(_pathFolders[i], oldPath)) {
            _pathFolders[i] =
                _replaceFolderPrefix(_pathFolders[i], oldPath, newPath);
          }
        }

        if (_pathFolder != null && _isInFolderTree(_pathFolder!, oldPath)) {
          _pathFolder = _replaceFolderPrefix(_pathFolder!, oldPath, newPath);
        }
      } else {
        for (final auto in _autos) {
          final folder = auto.folder;
          if (folder != null && _isInFolderTree(folder, oldPath)) {
            auto.folder = _replaceFolderPrefix(folder, oldPath, newPath);
            auto.saveFile();
          }
        }

        for (int i = 0; i < _autoFolders.length; i++) {
          if (_isInFolderTree(_autoFolders[i], oldPath)) {
            _autoFolders[i] =
                _replaceFolderPrefix(_autoFolders[i], oldPath, newPath);
          }
        }

        if (_autoFolder != null && _isInFolderTree(_autoFolder!, oldPath)) {
          _autoFolder = _replaceFolderPrefix(_autoFolder!, oldPath, newPath);
        }
      }
    });

    widget.prefs.setStringList(
        isPathsView ? PrefsKeys.pathFolders : PrefsKeys.autoFolders,
        isPathsView ? _pathFolders : _autoFolders);
    widget.onFoldersChanged?.call();
  }

  void _deleteFolderPath({
    required bool isPathsView,
    required String folder,
  }) {
    if (isPathsView) {
      for (final path in _paths.where(
          (p) => p.folder != null && _isInFolderTree(p.folder!, folder))) {
        path.deletePath();
      }

      setState(() {
        _paths.removeWhere(
            (p) => p.folder != null && _isInFolderTree(p.folder!, folder));
        _pathFolders.removeWhere((f) => _isInFolderTree(f, folder));
        if (_pathFolder != null && _isInFolderTree(_pathFolder!, folder)) {
          _pathFolder = _parentFolder(folder);
        }
      });

      widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
    } else {
      for (final auto in _autos.where(
          (a) => a.folder != null && _isInFolderTree(a.folder!, folder))) {
        auto.delete();
      }

      setState(() {
        _autos.removeWhere(
            (a) => a.folder != null && _isInFolderTree(a.folder!, folder));
        _autoFolders.removeWhere((f) => _isInFolderTree(f, folder));
        if (_autoFolder != null && _isInFolderTree(_autoFolder!, folder)) {
          _autoFolder = _parentFolder(folder);
        }
      });

      widget.prefs.setStringList(PrefsKeys.autoFolders, _autoFolders);
    }

    widget.onFoldersChanged?.call();
  }

  Widget _buildPathFolderCard(String folder, BuildContext context) {
    return DragTarget<PathPlannerPath>(
      onAcceptWithDetails: (details) {
        setState(() {
          details.data.folder = folder;
          details.data.generateAndSavePath();
        });
      },
      builder: (context, candidates, rejects) {
        ColorScheme colorScheme = Theme.of(context).colorScheme;
        return Card(
          elevation: 2,
          color:
              candidates.isNotEmpty ? colorScheme.primary : colorScheme.surface,
          surfaceTintColor: colorScheme.surfaceTint,
          child: InkWell(
            onTap: () {
              _navigatePathView(folder: folder, inChoreo: false);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    color: candidates.isNotEmpty ? colorScheme.onPrimary : null,
                  ),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: RenamableTitle(
                        title: _folderLeaf(folder),
                        textStyle: TextStyle(
                          fontSize: 20,
                          color: candidates.isNotEmpty
                              ? colorScheme.onPrimary
                              : null,
                        ),
                        onRename: (newName) => _renameFolderPath(
                          isPathsView: true,
                          oldPath: folder,
                          newLeaf: newName,
                          context: context,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAutoFolderCard(String folder, BuildContext context) {
    return DragTarget<PathPlannerAuto>(
      onAcceptWithDetails: (details) {
        setState(() {
          details.data.folder = folder;
          details.data.saveFile();
        });
      },
      builder: (context, candidates, rejects) {
        ColorScheme colorScheme = Theme.of(context).colorScheme;
        return Card(
          elevation: 2,
          color:
              candidates.isNotEmpty ? colorScheme.primary : colorScheme.surface,
          surfaceTintColor: colorScheme.surfaceTint,
          child: InkWell(
            onTap: () {
              _navigateAutoView(folder: folder);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    color: candidates.isNotEmpty ? colorScheme.onPrimary : null,
                  ),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: RenamableTitle(
                        title: _folderLeaf(folder),
                        textStyle: TextStyle(
                          fontSize: 20,
                          color: candidates.isNotEmpty
                              ? colorScheme.onPrimary
                              : null,
                        ),
                        onRename: (newName) => _renameFolderPath(
                          isPathsView: false,
                          oldPath: folder,
                          newLeaf: newName,
                          context: context,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _load() async {
    // Make sure dirs exist
    _pathsDirectory =
        fs.directory(join(widget.pathplannerDirectory.path, 'paths'));
    _pathsDirectory.createSync(recursive: true);
    _autosDirectory =
        fs.directory(join(widget.pathplannerDirectory.path, 'autos'));
    _autosDirectory.createSync(recursive: true);
    _choreoDirectory = fs.directory(widget.choreoDirectory);

    var paths =
        await PathPlannerPath.loadAllPathsInDir(_pathsDirectory.path, fs);
    var autos =
        await PathPlannerAuto.loadAllAutosInDir(_autosDirectory.path, fs);
    List<ChoreoPath> choreoPaths =
        await ChoreoPath.loadAllPathsInDir(_choreoDirectory.path, fs);

    List<String> allPathNames = [];
    for (PathPlannerPath path in paths) {
      allPathNames.add(path.name);
    }

    List<String> allChoreoPathNames = [];
    for (ChoreoPath path in choreoPaths) {
      allChoreoPathNames.add(path.name);
    }

    for (int i = 0; i < paths.length; i++) {
      if (!_pathFolders.contains(paths[i].folder)) {
        paths[i].folder = null;
      }
    }
    for (int i = 0; i < autos.length; i++) {
      if (!_autoFolders.contains(autos[i].folder)) {
        autos[i].folder = null;
      }

      autos[i].handleMissingPaths(
          autos[i].choreoAuto ? allChoreoPathNames : allPathNames);
    }

    _addMissingParentFolders(_pathFolders);
    _addMissingParentFolders(_autoFolders);

    if (!mounted) {
      return;
    }

    setState(() {
      _paths = paths;
      _autos = autos;
      _choreoPaths = choreoPaths;
      _pathFolder = null;
      _autoFolder = null;
      _inChoreoFolder = false;

      if (_paths.isEmpty) {
        _paths.add(PathPlannerPath.defaultPath(
          pathDir: _pathsDirectory.path,
          name: 'Example Path',
          fs: fs,
          constraints: _getDefaultConstraints(),
        ));
      }

      _sortPaths(_pathSortValue);
      _sortAutos(_autoSortValue);

      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    final availableWidth = MediaQuery.sizeOf(context).width - 32;
    final cardCols = _getCrossAxisCountForWidth(availableWidth);
    if (_layoutMode == 'professional') {
      _pathGridCount = cardCols;
      _autosGridCount = cardCols;
    }

    // Update _pathSortValue from shared preferences
    _pathSortValue = widget.prefs.getString(PrefsKeys.pathSortOption) ??
        Defaults.pathSortOption;

    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // Stupid workaround but it works
    if (ProjectPage.settingsUpdated) {
      PathConstraints defaultConstraints = _getDefaultConstraints();

      for (PathPlannerPath path in _paths) {
        if (path.useDefaultConstraints) {
          PathConstraints cloned = defaultConstraints.clone();
          cloned.unlimited = path.globalConstraints.unlimited;
          path.globalConstraints = cloned;
          path.generateAndSavePath();
        }
      }

      ProjectPage.settingsUpdated = false;
    }

    return Stack(
      children: [
        Container(
          color: colorScheme.surfaceTint.withAlpha(15),
          child: Column(
            children: [
              _buildBrowserTopMenu(context),
              Expanded(
                child: _layoutMode == 'professional'
                    ? Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: _activeSection == ProjectMenuSection.paths
                                ? _buildPathsGrid(context)
                                : _buildAutosGrid(context),
                          ),
                          Expanded(
                            flex: 1,
                            child: _buildProQuickCommandsPanel(context),
                          ),
                        ],
                      )
                    : MultiSplitViewTheme(
                        data: MultiSplitViewThemeData(
                          dividerPainter: DividerPainters.grooved1(
                            color: colorScheme.surfaceContainerHighest,
                            highlightedColor: colorScheme.primary,
                          ),
                        ),
                        child: MultiSplitView(
                          axis: Axis.horizontal,
                          controller: _controller,
                          onWeightChange: () {
                            setState(() {
                              _pathGridCount = _getCrossAxisCountForWeight(
                                  _controller.areas[0].weight!);
                              _autosGridCount = _getCrossAxisCountForWeight(
                                  1.0 - _controller.areas[0].weight!);
                            });
                            widget.prefs.setDouble(
                                PrefsKeys.projectLeftWeight,
                                _controller.areas[0].weight ??
                                    Defaults.projectLeftWeight);
                          },
                          children: [
                            _buildPathsGrid(context),
                            _buildAutosGrid(context),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: FloatingActionButton(
              clipBehavior: Clip.antiAlias,
              tooltip: 'Manage Events & Linked Waypoints',
              backgroundColor: colorScheme.surface,
              foregroundColor: colorScheme.onSurface,
              onPressed: () => _openManagementDialog(context),
              child: Stack(
                children: [
                  Container(
                    color: colorScheme.surfaceTint.withAlpha(30),
                  ),
                  const Center(child: Icon(Icons.edit_note_rounded)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBrowserTopMenu(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final setupNames = widget.fieldSetupNames ?? const <String>[];
    final selectedSetup = widget.selectedFieldSetupName;

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surface,
      ),
      child: Row(
        children: [
          const Icon(Icons.dashboard_customize_outlined),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Project Browser',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'professional', label: Text('Pro')),
              ButtonSegment(value: 'original', label: Text('Original')),
            ],
            selected: {_layoutMode},
            onSelectionChanged: (selection) {
              setState(() {
                _layoutMode = selection.first;
                widget.prefs
                    .setString(PrefsKeys.projectLayoutMode, _layoutMode);
              });
            },
          ),
          if (_layoutMode == 'professional') ...[
            const SizedBox(width: 8),
            SegmentedButton<ProjectMenuSection>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ProjectMenuSection.paths,
                  icon: Icon(Icons.alt_route),
                  label: Text('Paths'),
                ),
                ButtonSegment(
                  value: ProjectMenuSection.autos,
                  icon: Icon(Icons.smart_toy_outlined),
                  label: Text('Autos'),
                ),
              ],
              selected: {_activeSection},
              onSelectionChanged: (selection) {
                setState(() {
                  _activeSection = selection.first;
                });
              },
            ),
          ],
          const SizedBox(width: 8),
          if (setupNames.isNotEmpty)
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                value: setupNames.contains(selectedSetup)
                    ? selectedSetup
                    : setupNames.first,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                ),
                items: [
                  for (final name in setupNames)
                    DropdownMenuItem(
                      value: name,
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    widget.onFieldSetupSelected?.call(value);
                  }
                },
              ),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: widget.onManageFieldSetups,
            icon: const Icon(Icons.tune),
            label: const Text('Field Setup'),
          ),
        ],
      ),
    );
  }

  void _openManagementDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) => ManagementDialog(
        onEventRenamed: (String oldName, String newName) {
          setState(() {
            for (PathPlannerPath path in _paths) {
              for (EventMarker m in path.eventMarkers) {
                if (m.command != null) {
                  _replaceNamedCommand(oldName, newName, m.command!);
                }
                if (m.name == oldName) {
                  m.name = newName;
                }
              }
              path.generateAndSavePath();
            }

            for (PathPlannerAuto auto in _autos) {
              for (Command cmd in auto.sequence.commands) {
                _replaceNamedCommand(oldName, newName, cmd);
              }
              auto.saveFile();
            }
          });
        },
        onEventDeleted: (String name) {
          setState(() {
            for (PathPlannerPath path in _paths) {
              for (EventMarker m in path.eventMarkers) {
                if (m.command != null) {
                  _replaceNamedCommand(name, null, m.command!);
                }
                if (m.name == name) {
                  m.name = '';
                }
              }
              path.generateAndSavePath();
            }

            for (PathPlannerAuto auto in _autos) {
              for (Command cmd in auto.sequence.commands) {
                _replaceNamedCommand(name, null, cmd);
              }
              auto.saveFile();
            }
          });
        },
        onLinkedRenamed: (String oldName, String newName) {
          setState(() {
            Pose2d? pose = Waypoint.linked.remove(oldName);

            if (pose != null) {
              Waypoint.linked[newName] = pose;

              for (PathPlannerPath path in _paths) {
                bool changed = false;

                for (Waypoint w in path.waypoints) {
                  if (w.linkedName == oldName) {
                    w.linkedName = newName;
                    changed = true;
                  }
                }

                if (changed) {
                  path.generateAndSavePath();
                }
              }
            }
          });
        },
        onLinkedDeleted: (String name) {
          setState(() {
            Waypoint.linked.remove(name);

            for (PathPlannerPath path in _paths) {
              bool changed = false;

              for (Waypoint w in path.waypoints) {
                if (w.linkedName == name) {
                  w.linkedName = null;
                  changed = true;
                }
              }

              if (changed) {
                path.generateAndSavePath();
              }
            }
          });
        },
      ),
    );
  }

  Widget _buildProQuickCommandsPanel(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPaths = _activeSection == ProjectMenuSection.paths;
    final activeFolder = isPaths ? _pathFolder : _autoFolder;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
      child: Card(
        margin: EdgeInsets.zero,
        color: colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SingleChildScrollView(
            child: Column(
              children: [
                _buildQuickSection(
                  buildContext: this.context,
                  title: 'Layout & Section',
                  icon: Icons.dashboard_customize_outlined,
                  expanded: _quickLayoutExpanded,
                  onExpandedChanged: (value) =>
                      setState(() => _quickLayoutExpanded = value),
                  children: [
                    _buildQuickCmd(
                      icon: Icons.alt_route,
                      label: 'Paths',
                      onTap: () => setState(() {
                        _activeSection = ProjectMenuSection.paths;
                      }),
                    ),
                    _buildQuickCmd(
                      icon: Icons.smart_toy_outlined,
                      label: 'Autos',
                      onTap: () => setState(() {
                        _activeSection = ProjectMenuSection.autos;
                      }),
                    ),
                    _buildQuickCmd(
                      icon: Icons.account_tree_outlined,
                      label: 'Original',
                      onTap: () => setState(() {
                        _layoutMode = 'original';
                        widget.prefs.setString(
                            PrefsKeys.projectLayoutMode, _layoutMode);
                      }),
                    ),
                    _buildQuickCmd(
                      icon: Icons.dashboard_customize_outlined,
                      label: 'Pro',
                      onTap: () => setState(() {
                        _layoutMode = 'professional';
                        widget.prefs.setString(
                            PrefsKeys.projectLayoutMode, _layoutMode);
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildQuickSection(
                  buildContext: this.context,
                  title: 'Folders & Search',
                  icon: Icons.folder_open,
                  expanded: _quickFolderExpanded,
                  onExpandedChanged: (value) =>
                      setState(() => _quickFolderExpanded = value),
                  children: [
                    _buildQuickCmd(
                      icon: Icons.home_outlined,
                      label: 'Root',
                      onTap: _goToRootFolder,
                    ),
                    _buildQuickCmd(
                      icon: Icons.arrow_upward_rounded,
                      label: 'Up',
                      enabled: activeFolder != null,
                      onTap: _goToParentFolder,
                    ),
                    _buildQuickCmd(
                      icon: Icons.folder_copy_outlined,
                      label: 'New Folder',
                      onTap: _createFolderInCurrentSection,
                    ),
                    _buildQuickCmd(
                      icon: Icons.create_new_folder_outlined,
                      label: 'Subfolder',
                      enabled: activeFolder != null,
                      onTap: _createSubfolderInCurrentSection,
                    ),
                    _buildQuickCmd(
                      icon: Icons.delete_forever_rounded,
                      label: 'Delete Folder',
                      enabled: activeFolder != null,
                      onTap: _deleteCurrentFolder,
                    ),
                    _buildQuickCmd(
                      icon: Icons.clear_rounded,
                      label: 'Clear Search',
                      onTap: _clearCurrentSearch,
                    ),
                    _buildQuickCmd(
                      icon: Icons.folder_special_outlined,
                      label: 'Choreo Folder',
                      enabled: isPaths,
                      onTap: () {
                        if (!isPaths) return;
                        setState(() {
                          _inChoreoFolder = true;
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildQuickSection(
                  buildContext: this.context,
                  title: 'View & Sort',
                  icon: Icons.tune,
                  expanded: _quickViewExpanded,
                  onExpandedChanged: (value) =>
                      setState(() => _quickViewExpanded = value),
                  children: [
                    _buildQuickCmd(
                      icon: Icons.view_list_rounded,
                      label: 'Compact',
                      onTap: _setCurrentCompactOn,
                    ),
                    _buildQuickCmd(
                      icon: Icons.grid_view_rounded,
                      label: 'Default View',
                      onTap: _setCurrentCompactOff,
                    ),
                    _buildQuickCmd(
                      icon: Icons.history,
                      label: 'Sort Recent',
                      onTap: () => _setCurrentSort('recent'),
                    ),
                    _buildQuickCmd(
                      icon: Icons.sort_by_alpha,
                      label: 'Sort A-Z',
                      onTap: () => _setCurrentSort('nameAsc'),
                    ),
                    _buildQuickCmd(
                      icon: Icons.sort_by_alpha_outlined,
                      label: 'Sort Z-A',
                      onTap: () => _setCurrentSort('nameDesc'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildQuickSection(
                  buildContext: this.context,
                  title: 'Create',
                  icon: Icons.add_circle_outline,
                  expanded: _quickCreateExpanded,
                  onExpandedChanged: (value) =>
                      setState(() => _quickCreateExpanded = value),
                  children: [
                    if (isPaths)
                      _buildQuickCmd(
                        icon: Icons.add_rounded,
                        label: 'New Path',
                        onTap: _createNewPath,
                      ),
                    if (!isPaths)
                      _buildQuickCmd(
                        icon: Icons.add_rounded,
                        label: 'New Auto',
                        onTap: () => _createNewAuto(),
                      ),
                    if (!isPaths)
                      _buildQuickCmd(
                        icon: Icons.auto_awesome_motion,
                        label: 'New Choreo Auto',
                        onTap: () => _createNewAuto(choreo: true),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildQuickSection(
                  buildContext: this.context,
                  title: 'Management',
                  icon: Icons.admin_panel_settings_outlined,
                  expanded: _quickManageExpanded,
                  onExpandedChanged: (value) =>
                      setState(() => _quickManageExpanded = value),
                  children: [
                    _buildQuickCmd(
                      icon: Icons.checklist_rtl_rounded,
                      label: 'Bulk Delete',
                      onTap: () => _showBulkDeleteDialog(isPaths),
                    ),
                    _buildQuickCmd(
                      icon: Icons.edit_note_rounded,
                      label: 'Manage Events',
                      onTap: () {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        _openManagementDialog(this.context);
                      },
                    ),
                    _buildQuickCmd(
                      icon: Icons.refresh_rounded,
                      label: 'Reload',
                      onTap: _load,
                    ),
                    _buildQuickCmd(
                      icon: Icons.file_upload_outlined,
                      label: 'Import Package',
                      onTap: _importPackage,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickSection({
    required BuildContext buildContext,
    required String title,
    required IconData icon,
    required bool expanded,
    required ValueChanged<bool> onExpandedChanged,
    required List<Widget> children,
  }) {
    final colorScheme = Theme.of(buildContext).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
      ),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: onExpandedChanged,
        leading: Icon(icon, size: 18),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.6,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: children,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickCmd({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  void _goToRootFolder() {
    _goHomeFolder(isPathsView: _activeSection == ProjectMenuSection.paths);
  }

  void _goToParentFolder() {
    _goUpFolder(isPathsView: _activeSection == ProjectMenuSection.paths);
  }

  void _createFolderInCurrentSection() {
    if (_activeSection == ProjectMenuSection.paths) {
      final folderPath = _newUniqueFolderPath(_pathFolders, _pathFolder);
      setState(() {
        _pathFolders.add(folderPath);
        _sortPaths(_pathSortValue);
      });
      widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
      widget.onFoldersChanged?.call();
    } else {
      final folderPath = _newUniqueFolderPath(_autoFolders, _autoFolder);
      setState(() {
        _autoFolders.add(folderPath);
        _sortAutos(_autoSortValue);
      });
      widget.prefs.setStringList(PrefsKeys.autoFolders, _autoFolders);
      widget.onFoldersChanged?.call();
    }
  }

  void _createSubfolderInCurrentSection() {
    if (_activeSection == ProjectMenuSection.paths && _pathFolder != null) {
      final folderPath = _newUniqueFolderPath(_pathFolders, _pathFolder);
      setState(() {
        _pathFolders.add(folderPath);
        _sortPaths(_pathSortValue);
      });
      widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
      widget.onFoldersChanged?.call();
    } else if (_activeSection == ProjectMenuSection.autos &&
        _autoFolder != null) {
      final folderPath = _newUniqueFolderPath(_autoFolders, _autoFolder);
      setState(() {
        _autoFolders.add(folderPath);
        _sortAutos(_autoSortValue);
      });
      widget.prefs.setStringList(PrefsKeys.autoFolders, _autoFolders);
      widget.onFoldersChanged?.call();
    }
  }

  void _deleteCurrentFolder() {
    final folder =
        _activeSection == ProjectMenuSection.paths ? _pathFolder : _autoFolder;
    if (folder == null) return;
    _deleteFolderPath(
      isPathsView: _activeSection == ProjectMenuSection.paths,
      folder: folder,
    );
  }

  void _clearCurrentSearch() {
    setState(() {
      if (_activeSection == ProjectMenuSection.paths) {
        _pathSearchQuery = '';
        _pathSearchController.clear();
      } else {
        _autoSearchQuery = '';
        _autoSearchController.clear();
      }
    });
  }

  void _setCurrentCompactOn() {
    setState(() {
      if (_activeSection == ProjectMenuSection.paths) {
        _pathsCompact = true;
        widget.prefs.setBool(PrefsKeys.pathsCompactView, true);
      } else {
        _autosCompact = true;
        widget.prefs.setBool(PrefsKeys.autosCompactView, true);
      }
    });
  }

  void _setCurrentCompactOff() {
    setState(() {
      if (_activeSection == ProjectMenuSection.paths) {
        _pathsCompact = false;
        widget.prefs.setBool(PrefsKeys.pathsCompactView, false);
      } else {
        _autosCompact = false;
        widget.prefs.setBool(PrefsKeys.autosCompactView, false);
      }
    });
  }

  void _setCurrentSort(String sortValue) {
    setState(() {
      if (_activeSection == ProjectMenuSection.paths) {
        _pathSortValue = sortValue;
        widget.prefs.setString(PrefsKeys.pathSortOption, sortValue);
        _sortPaths(sortValue);
      } else {
        _autoSortValue = sortValue;
        widget.prefs.setString(PrefsKeys.autoSortOption, sortValue);
        _sortAutos(sortValue);
      }
    });
  }

  void _createNewPath() {
    List<String> pathNames = [];
    for (PathPlannerPath path in _paths) {
      pathNames.add(path.name);
    }
    String pathName = 'New Path';
    while (pathNames.contains(pathName)) {
      pathName = 'New $pathName';
    }

    setState(() {
      _paths.add(PathPlannerPath.defaultPath(
        pathDir: _pathsDirectory.path,
        name: pathName,
        fs: fs,
        folder: _pathFolder,
        constraints: _getDefaultConstraints(),
      ));
      _sortPaths(_pathSortValue);
    });
  }

  void _replaceNamedCommand(
      String originalName, String? newName, Command command) {
    if (command is NamedCommand && command.name == originalName) {
      command.name = newName;
    } else if (command is CommandGroup) {
      for (Command cmd in command.commands) {
        _replaceNamedCommand(originalName, newName, cmd);
      }
    }
  }

  Widget _buildPaneHeader({
    required BuildContext context,
    required String title,
    required int itemCount,
    required int folderCount,
    required String? selectedFolder,
    required bool isPathsView,
    required bool isSearching,
    required String searchQuery,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final location = selectedFolder == null
        ? 'Root Folder'
        : selectedFolder.replaceAll('/', ' / ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                isSearching
                    ? 'Searching "${searchQuery.trim()}"'
                    : '$itemCount items • $folderCount folders',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                tooltip: 'Back',
                onPressed:
                    (isPathsView ? _pathBackStack : _autoBackStack).isNotEmpty
                        ? () => _goBackFolder(isPathsView: isPathsView)
                        : null,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                tooltip: 'Forward',
                onPressed: (isPathsView ? _pathForwardStack : _autoForwardStack)
                        .isNotEmpty
                    ? () => _goForwardFolder(isPathsView: isPathsView)
                    : null,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                tooltip: 'Up',
                onPressed: () => _goUpFolder(isPathsView: isPathsView),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                tooltip: 'Home',
                onPressed: () => _goHomeFolder(isPathsView: isPathsView),
                icon: const Icon(Icons.home_outlined),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.folder_open, size: 16),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPathsGrid(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool isSearching = _pathSearchQuery.trim().isNotEmpty;

    if (_inChoreoFolder && !isSearching) {
      return Padding(
        padding: const EdgeInsets.all(8.0),
        child: Card(
          elevation: 0.0,
          margin: const EdgeInsets.all(0),
          color: colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPaneHeader(
                  context: context,
                  title: 'Paths',
                  itemCount: _paths.length,
                  folderCount: _pathFolders.length,
                  selectedFolder: _pathFolder,
                  isPathsView: true,
                  isSearching: isSearching,
                  searchQuery: _pathSearchQuery,
                ),
                const SizedBox(height: 8),
                _buildOptionsRow(
                  sortValue: _pathSortValue,
                  viewValue: _pathsCompact,
                  onSortChanged: (value) async {
                    await widget.prefs
                        .setString(PrefsKeys.pathSortOption, value);
                    setState(() {
                      _pathSortValue = value;
                      _sortPaths(_pathSortValue);
                    });
                  },
                  onViewChanged: (value) {
                    widget.prefs.setBool(PrefsKeys.pathsCompactView, value);
                    setState(() {
                      _pathsCompact = value;
                    });
                  },
                  onSearchChanged: (value) {
                    setState(() {
                      _pathSearchQuery = value;
                    });
                  },
                  searchController: _pathSearchController,
                  onAddFolder: () {
                    final folderPath =
                        _newUniqueFolderPath(_pathFolders, _pathFolder);

                    setState(() {
                      _pathFolders.add(folderPath);
                      _sortPaths(_pathSortValue);
                    });
                    widget.prefs
                        .setStringList(PrefsKeys.pathFolders, _pathFolders);
                    widget.onFoldersChanged?.call();
                  },
                  onAddItem: () {
                    List<String> pathNames = [];
                    for (PathPlannerPath path in _paths) {
                      pathNames.add(path.name);
                    }
                    String pathName = 'New Path';
                    while (pathNames.contains(pathName)) {
                      pathName = 'New $pathName';
                    }

                    setState(() {
                      _paths.add(PathPlannerPath.defaultPath(
                        pathDir: _pathsDirectory.path,
                        name: pathName,
                        fs: fs,
                        folder: _pathFolder,
                        constraints: _getDefaultConstraints(),
                      ));
                      _sortPaths(_pathSortValue);
                    });
                  },
                  isPathsView: true,
                ),
                GridView.count(
                  crossAxisCount: _pathGridCount,
                  childAspectRatio: 7.0,
                  shrinkWrap: true,
                  children: [
                    Card(
                      elevation: 2,
                      child: InkWell(
                        onTap: () {
                          _navigatePathView(
                              folder: _pathFolder, inChoreo: false);
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8.0),
                          child: Row(
                            children: [
                              Icon(Icons.drive_file_move_rtl_outlined),
                              SizedBox(width: 12),
                              Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Parent Folder',
                                    style: TextStyle(
                                      fontSize: 20,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: _pathGridCount,
                    childAspectRatio: 1.9,
                    children: [
                      for (int i = 0; i < _choreoPaths.length; i++)
                        _buildChoreoPathCard(i, context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        elevation: 0.0,
        margin: const EdgeInsets.all(0),
        color: colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              _buildPaneHeader(
                context: context,
                title: 'Paths',
                itemCount: _paths.length,
                folderCount: _pathFolders.length,
                selectedFolder: _pathFolder,
                isPathsView: true,
                isSearching: isSearching,
                searchQuery: _pathSearchQuery,
              ),
              const SizedBox(height: 8),
              _buildOptionsRow(
                sortValue: _pathSortValue,
                viewValue: _pathsCompact,
                onSortChanged: (value) {
                  widget.prefs.setString(PrefsKeys.pathSortOption, value);
                  setState(() {
                    _pathSortValue = value;
                    _sortPaths(_pathSortValue);
                  });
                },
                onViewChanged: (value) {
                  widget.prefs.setBool(PrefsKeys.pathsCompactView, value);
                  setState(() {
                    _pathsCompact = value;
                  });
                },
                onSearchChanged: (value) {
                  setState(() {
                    _pathSearchQuery = value;
                  });
                },
                searchController: _pathSearchController,
                onAddFolder: () {
                  final folderPath =
                      _newUniqueFolderPath(_pathFolders, _pathFolder);

                  setState(() {
                    _pathFolders.add(folderPath);
                    _sortPaths(_pathSortValue);
                  });
                  widget.prefs
                      .setStringList(PrefsKeys.pathFolders, _pathFolders);
                  widget.onFoldersChanged?.call();
                },
                onAddItem: () {
                  List<String> pathNames = [];
                  for (PathPlannerPath path in _paths) {
                    pathNames.add(path.name);
                  }
                  String pathName = 'New Path';
                  while (pathNames.contains(pathName)) {
                    pathName = 'New $pathName';
                  }

                  setState(() {
                    _paths.add(PathPlannerPath.defaultPath(
                      pathDir: _pathsDirectory.path,
                      name: pathName,
                      fs: fs,
                      folder: _pathFolder,
                      constraints: _getDefaultConstraints(),
                    ));
                    _sortPaths(_pathSortValue);
                  });
                },
                isPathsView: true,
              ),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (!isSearching)
                      ConditionalWidget(
                        condition: _pathFolder == null,
                        falseChild: GridView.count(
                          crossAxisCount: _pathGridCount,
                          childAspectRatio: 7.0,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            DragTarget<PathPlannerPath>(
                              onAcceptWithDetails: (details) {
                                final parentFolder = _pathFolder == null
                                    ? null
                                    : _parentFolder(_pathFolder!);
                                setState(() {
                                  details.data.folder = parentFolder;
                                  details.data.generateAndSavePath();
                                });
                              },
                              builder: (context, candidates, rejects) {
                                ColorScheme colorScheme =
                                    Theme.of(context).colorScheme;
                                return Card(
                                  elevation: 2,
                                  color: candidates.isNotEmpty
                                      ? colorScheme.primary
                                      : colorScheme.surface,
                                  surfaceTintColor: colorScheme.surfaceTint,
                                  child: InkWell(
                                    onTap: () {
                                      _navigatePathView(
                                          folder: _pathFolder == null
                                              ? null
                                              : _parentFolder(_pathFolder!),
                                          inChoreo: false);
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8.0),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.drive_file_move_rtl_outlined,
                                            color: candidates.isNotEmpty
                                                ? colorScheme.onPrimary
                                                : null,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                'Parent Folder',
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  color: candidates.isNotEmpty
                                                      ? colorScheme.onPrimary
                                                      : null,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            for (final folder
                                in _childFolders(_pathFolders, _pathFolder))
                              _buildPathFolderCard(folder, context),
                          ],
                        ),
                        trueChild: GridView.count(
                          crossAxisCount: _pathGridCount,
                          childAspectRatio: 7.0,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            if (_choreoPaths.isNotEmpty)
                              Card(
                                elevation: 2,
                                color: colorScheme.surface,
                                surfaceTintColor: colorScheme.surfaceTint,
                                child: InkWell(
                                  onTap: () {
                                    _navigatePathView(
                                        folder: _pathFolder, inChoreo: true);
                                  },
                                  child: const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 8.0),
                                    child: Row(
                                      children: [
                                        Icon(Icons.folder_outlined),
                                        SizedBox(width: 12),
                                        Expanded(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'Choreo Paths',
                                              style: TextStyle(
                                                fontSize: 20,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            for (final folder
                                in _childFolders(_pathFolders, _pathFolder))
                              _buildPathFolderCard(folder, context),
                          ],
                        ),
                      ),
                    if (!isSearching &&
                        (_pathFolders.isNotEmpty || _choreoPaths.isNotEmpty))
                      const SizedBox(height: 8),
                    if (isSearching)
                      _buildPathSearchResults(context)
                    else
                      GridView.count(
                        crossAxisCount: _pathGridCount,
                        childAspectRatio: 1.9,
                        physics: const NeverScrollableScrollPhysics(),
                        shrinkWrap: true,
                        children: [
                          for (int i = 0; i < _paths.length; i++)
                            if (_matchesFolderFilter(_paths[i].folder,
                                    _pathFolder, _pathSearchQuery) &&
                                _paths[i]
                                    .name
                                    .toLowerCase()
                                    .contains(_pathSearchQuery.toLowerCase()))
                              _buildPathCard(i, context),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPathSearchResults(BuildContext context) {
    final query = _pathSearchQuery.trim().toLowerCase();
    final Map<String?, List<int>> grouped = {};

    for (int i = 0; i < _paths.length; i++) {
      if (_paths[i].name.toLowerCase().contains(query)) {
        grouped.putIfAbsent(_paths[i].folder, () => []).add(i);
      }
    }

    final folders = grouped.keys.toList()
      ..sort((a, b) {
        if (a == null && b == null) return 0;
        if (a == null) return -1;
        if (b == null) return 1;
        return a.compareTo(b);
      });

    if (folders.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('No paths match your search')),
      );
    }

    return Column(
      children: [
        for (final folder in folders) ...[
          _buildSearchGroupHeader(folder, context),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: _pathGridCount,
            childAspectRatio: 1.9,
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            children: [
              for (final index in grouped[folder]!)
                _buildPathCard(index, context),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildSearchGroupHeader(String? folder, BuildContext buildContext) {
    final label =
        folder == null ? 'Root Folder' : folder.replaceAll('/', ' / ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(buildContext).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_open_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPathCard(int i, BuildContext context) {
    final pathCard = ProjectItemCard(
      name: _paths[i].name,
      compact: _pathsCompact,
      fieldImage: widget.fieldImage,
      paths: [_paths[i].pathPositions],
      warningMessage: _paths[i].hasEmptyNamedCommand()
          ? 'Contains a NamedCommand that does not have a command selected'
          : null,
      onDuplicated: () {
        List<String> pathNames = [];
        for (PathPlannerPath path in _paths) {
          pathNames.add(path.name);
        }
        String pathName = 'Copy of ${_paths[i].name}';
        while (pathNames.contains(pathName)) {
          pathName = 'Copy of $pathName';
        }

        setState(() {
          _paths.add(_paths[i].duplicate(pathName));
          _sortPaths(_pathSortValue);
        });
      },
      onDeleted: () {
        _paths[i].deletePath();
        setState(() {
          _paths.removeAt(i);
        });

        List<String> allPathNames = _paths.map((e) => e.name).toList();
        for (PathPlannerAuto auto in _autos) {
          if (!auto.choreoAuto) {
            auto.handleMissingPaths(allPathNames);
          }
        }
      },
      onRenamed: (value) => _renamePath(_paths[i], value, context),
      onExport: () => _exportPathPackage(_paths[i]),
      onShowFile: () =>
          _showFile(join(_paths[i].pathDir, '${_paths[i].name}.path')),
      onOpened: () => _openPath(_paths[i]),
    );

    return LayoutBuilder(builder: (context, constraints) {
      return Draggable<PathPlannerPath>(
        data: _paths[i],
        feedback: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Opacity(
            opacity: 0.8,
            child: pathCard,
          ),
        ),
        childWhenDragging: Container(),
        child: pathCard,
      );
    });
  }

  Widget _buildChoreoPathCard(int i, BuildContext context) {
    final pathCard = ProjectItemCard(
      name: _choreoPaths[i].name,
      compact: _pathsCompact,
      fieldImage: widget.fieldImage,
      showOptions: false,
      paths: [_choreoPaths[i].pathPositions],
      choreoItem: true,
      onOpened: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChoreoPathEditorPage(
              prefs: widget.prefs,
              path: _choreoPaths[i],
              fieldImage: widget.fieldImage,
              undoStack: widget.undoStack,
              shortcuts: widget.shortcuts,
              simulatePath: widget.simulatePath,
            ),
          ),
        );
      },
    );

    return LayoutBuilder(builder: (context, constraints) {
      return Draggable<ChoreoPath>(
        data: _choreoPaths[i],
        feedback: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Opacity(
            opacity: 0.8,
            child: pathCard,
          ),
        ),
        childWhenDragging: Container(),
        child: pathCard,
      );
    });
  }

  void _openPath(PathPlannerPath path) async {
    await Navigator.push(
      this.context,
      MaterialPageRoute(
        builder: (context) => PathEditorPage(
          prefs: widget.prefs,
          path: path,
          fieldImage: widget.fieldImage,
          fieldProfile: widget.fieldProfile ?? FieldConstraintsProfile.empty(),
          hiddenFieldZoneNames: widget.hiddenFieldZoneNames ?? const [],
          undoStack: widget.undoStack,
          onRenamed: (value) => _renamePath(path, value, context),
          shortcuts: widget.shortcuts,
          telemetry: widget.telemetry,
          hotReload: widget.hotReload,
          simulatePath: widget.simulatePath,
          onPathChanged: () {
            // Update the linked rotation for the start/end states
            if (path.waypoints.first.linkedName != null) {
              Waypoint.linked[path.waypoints.first.linkedName!] = Pose2d(
                  path.waypoints.first.anchor,
                  path.idealStartingState.rotation);
            }
            if (path.waypoints.last.linkedName != null) {
              Waypoint.linked[path.waypoints.last.linkedName!] = Pose2d(
                  path.waypoints.last.anchor, path.goalEndState.rotation);
            }

            // Make sure all paths with linked waypoints are updated
            for (PathPlannerPath p in _paths) {
              bool changed = false;

              for (int i = 0; i < p.waypoints.length; i++) {
                Waypoint w = p.waypoints[i];
                if (w.linkedName != null &&
                    Waypoint.linked.containsKey(w.linkedName!)) {
                  Pose2d link = Waypoint.linked[w.linkedName!]!;

                  if (link.translation.getDistance(w.anchor) >= 0.01) {
                    w.move(link.translation.x, link.translation.y);
                    changed = true;
                  }

                  if (i == 0 &&
                      (link.rotation - p.idealStartingState.rotation)
                              .degrees
                              .abs() >
                          0.01) {
                    p.idealStartingState.rotation = link.rotation;
                    changed = true;
                  } else if (i == p.waypoints.length - 1 &&
                      (link.rotation - p.goalEndState.rotation).degrees.abs() >
                          0.01) {
                    p.goalEndState.rotation = link.rotation;
                    changed = true;
                  }
                }
              }

              if (changed) {
                p.generateAndSavePath();

                if (widget.hotReload) {
                  widget.telemetry?.hotReloadPath(p);
                }
              }
            }
          },
        ),
      ),
    );

    setState(() {
      _sortPaths(_pathSortValue);
    });
  }

  void _renamePath(PathPlannerPath path, String newName, BuildContext context) {
    List<String> pathNames = [];
    for (PathPlannerPath p in _paths) {
      pathNames.add(p.name);
    }

    if (pathNames.contains(newName)) {
      showDialog(
          context: context,
          builder: (BuildContext context) {
            ColorScheme colorScheme = Theme.of(context).colorScheme;
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: const Text('Unable to Rename'),
              content: Text('The file "$newName.path" already exists'),
              actions: [
                TextButton(
                  onPressed: Navigator.of(context).pop,
                  child: const Text('OK'),
                ),
              ],
            );
          });
    } else {
      String oldName = path.name;
      setState(() {
        path.renamePath(newName);
        for (PathPlannerAuto auto in _autos) {
          auto.updatePathName(oldName, newName);
        }
        _sortPaths(_pathSortValue);
      });
    }
  }

  int _getCrossAxisCountForWidth(double width) {
    if (width < 760) {
      return 1;
    } else if (width < 980) {
      return 2;
    } else if (width < 1250) {
      return 3;
    } else {
      return 4;
    }
  }

  int _getCrossAxisCountForWeight(double weight) {
    if (weight < 0.4) {
      return 1;
    } else if (weight < 0.6) {
      return 2;
    } else {
      return 3;
    }
  }

  Widget _buildAutosGrid(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool isSearching = _autoSearchQuery.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        elevation: 0.0,
        margin: const EdgeInsets.all(0),
        color: colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              _buildPaneHeader(
                context: context,
                title: 'Autos',
                itemCount: _autos.length,
                folderCount: _autoFolders.length,
                selectedFolder: _autoFolder,
                isPathsView: false,
                isSearching: isSearching,
                searchQuery: _autoSearchQuery,
              ),
              const SizedBox(height: 8),
              _buildOptionsRow(
                sortValue: _autoSortValue,
                viewValue: _autosCompact,
                onSortChanged: (value) {
                  widget.prefs.setString(PrefsKeys.autoSortOption, value);
                  setState(() {
                    _autoSortValue = value;
                    _sortAutos(_autoSortValue);
                  });
                },
                onViewChanged: (value) {
                  widget.prefs.setBool(PrefsKeys.autosCompactView, value);
                  setState(() {
                    _autosCompact = value;
                  });
                },
                onSearchChanged: (value) {
                  setState(() {
                    _autoSearchQuery = value;
                  });
                },
                searchController: _autoSearchController,
                onAddFolder: () {
                  final folderPath =
                      _newUniqueFolderPath(_autoFolders, _autoFolder);

                  setState(() {
                    _autoFolders.add(folderPath);
                    _sortAutos(_autoSortValue);
                  });
                  widget.prefs
                      .setStringList(PrefsKeys.autoFolders, _autoFolders);
                  widget.onFoldersChanged?.call();
                },
                onAddItem: () {
                  if (_choreoPaths.isNotEmpty) {
                    final RenderBox renderBox = _addAutoKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    final Size size = renderBox.size;
                    final Offset offset = renderBox.localToGlobal(Offset.zero);

                    showMenu(
                      context: context,
                      position: RelativeRect.fromLTRB(
                        offset.dx,
                        offset.dy + size.height,
                        offset.dx + size.width,
                        offset.dy + size.height,
                      ),
                      items: [
                        PopupMenuItem(
                          child: const Text('New PathPlanner Auto'),
                          onTap: () => _createNewAuto(),
                        ),
                        PopupMenuItem(
                          child: const Text('New Choreo Auto'),
                          onTap: () => _createNewAuto(choreo: true),
                        ),
                      ],
                    );
                  } else {
                    _createNewAuto();
                  }
                },
                isPathsView: false,
              ),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (!isSearching)
                      ConditionalWidget(
                        condition: _autoFolder == null,
                        falseChild: GridView.count(
                          crossAxisCount: _autosGridCount,
                          childAspectRatio: 7.0,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            DragTarget<PathPlannerAuto>(
                              onAcceptWithDetails: (details) {
                                final parentFolder = _autoFolder == null
                                    ? null
                                    : _parentFolder(_autoFolder!);
                                setState(() {
                                  details.data.folder = parentFolder;
                                  details.data.saveFile();
                                });
                              },
                              builder: (context, candidates, rejects) {
                                ColorScheme colorScheme =
                                    Theme.of(context).colorScheme;
                                return Card(
                                  elevation: 2,
                                  color: candidates.isNotEmpty
                                      ? colorScheme.primary
                                      : colorScheme.surface,
                                  surfaceTintColor: colorScheme.surfaceTint,
                                  child: InkWell(
                                    onTap: () {
                                      _navigateAutoView(
                                          folder: _autoFolder == null
                                              ? null
                                              : _parentFolder(_autoFolder!));
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8.0),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.drive_file_move_rtl_outlined,
                                            color: candidates.isNotEmpty
                                                ? colorScheme.onPrimary
                                                : null,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                'Parent Folder',
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  color: candidates.isNotEmpty
                                                      ? colorScheme.onPrimary
                                                      : null,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            for (final folder
                                in _childFolders(_autoFolders, _autoFolder))
                              _buildAutoFolderCard(folder, context),
                          ],
                        ),
                        trueChild: GridView.count(
                          crossAxisCount: _autosGridCount,
                          childAspectRatio: 7.0,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            for (final folder
                                in _childFolders(_autoFolders, _autoFolder))
                              _buildAutoFolderCard(folder, context),
                          ],
                        ),
                      ),
                    if (!isSearching && _autoFolders.isNotEmpty)
                      const SizedBox(height: 8),
                    if (isSearching)
                      _buildAutoSearchResults(context)
                    else
                      GridView.count(
                        crossAxisCount: _autosGridCount,
                        childAspectRatio: 1.9,
                        physics: const NeverScrollableScrollPhysics(),
                        shrinkWrap: true,
                        children: [
                          for (int i = 0; i < _autos.length; i++)
                            if (_matchesFolderFilter(_autos[i].folder,
                                    _autoFolder, _autoSearchQuery) &&
                                _autos[i]
                                    .name
                                    .toLowerCase()
                                    .contains(_autoSearchQuery.toLowerCase()))
                              _buildAutoCard(i, context),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutoSearchResults(BuildContext context) {
    final query = _autoSearchQuery.trim().toLowerCase();
    final Map<String?, List<int>> grouped = {};

    for (int i = 0; i < _autos.length; i++) {
      if (_autos[i].name.toLowerCase().contains(query)) {
        grouped.putIfAbsent(_autos[i].folder, () => []).add(i);
      }
    }

    final folders = grouped.keys.toList()
      ..sort((a, b) {
        if (a == null && b == null) return 0;
        if (a == null) return -1;
        if (b == null) return 1;
        return a.compareTo(b);
      });

    if (folders.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('No autos match your search')),
      );
    }

    return Column(
      children: [
        for (final folder in folders) ...[
          _buildSearchGroupHeader(folder, context),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: _autosGridCount,
            childAspectRatio: 1.9,
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            children: [
              for (final index in grouped[folder]!)
                _buildAutoCard(index, context),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildAutoCard(int i, BuildContext context) {
    String? warningMessage;

    if (_autos[i].hasEmptyPathCommands()) {
      warningMessage =
          'Contains a FollowPathCommand that does not have a path selected';
    } else if (_autos[i].hasEmptyNamedCommand()) {
      warningMessage =
          'Contains a NamedCommand that does not have a command selected';
    }

    final autoCard = ProjectItemCard(
      name: _autos[i].name,
      compact: _autosCompact,
      fieldImage: widget.fieldImage,
      choreoItem: _autos[i].choreoAuto,
      paths: _autos[i].choreoAuto
          ? [
              for (ChoreoPath path
                  in _getChoreoPathsFromNames(_autos[i].getAllPathNames()))
                path.pathPositions,
            ]
          : [
              for (PathPlannerPath path
                  in _getPathsFromNames(_autos[i].getAllPathNames()))
                path.pathPositions,
            ],
      onDuplicated: () {
        List<String> autoNames = [];
        for (PathPlannerAuto auto in _autos) {
          autoNames.add(auto.name);
        }
        String autoName = 'Copy of ${_autos[i].name}';
        while (autoNames.contains(autoName)) {
          autoName = 'Copy of $autoName';
        }

        setState(() {
          _autos.add(_autos[i].duplicate(autoName));
          _sortAutos(_autoSortValue);
        });
      },
      onDeleted: () {
        _autos[i].delete();
        setState(() {
          _autos.removeAt(i);
        });
      },
      onRenamed: (value) => _renameAuto(i, value, context),
      onExport: () => _exportAutoPackage(_autos[i]),
      onShowFile: () =>
          _showFile(join(_autos[i].autoDir, '${_autos[i].name}.auto')),
      onOpened: () async {
        String? pathNameToOpen = await Navigator.push<String?>(
          context,
          MaterialPageRoute(
            builder: (context) => AutoEditorPage(
              prefs: widget.prefs,
              auto: _autos[i],
              allPaths: _paths,
              allChoreoPaths: _choreoPaths,
              undoStack: widget.undoStack,
              allPathNames: _autos[i].choreoAuto
                  ? _choreoPaths.map((e) => e.name).toList()
                  : _paths.map((e) => e.name).toList(),
              fieldImage: widget.fieldImage,
              onRenamed: (value) => _renameAuto(i, value, context),
              shortcuts: widget.shortcuts,
              telemetry: widget.telemetry,
              hotReload: widget.hotReload,
            ),
          ),
        );
        setState(() {
          _sortAutos(_autoSortValue);
        });

        if (pathNameToOpen != null) {
          final pathToOpen =
              _paths.firstWhereOrNull((p) => p.name == pathNameToOpen);
          if (pathToOpen != null) {
            _openPath(pathToOpen);
          }
        }
      },
      warningMessage: warningMessage,
    );

    return LayoutBuilder(builder: (context, constraints) {
      return Draggable<PathPlannerAuto>(
        data: _autos[i],
        feedback: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Opacity(
            opacity: 0.8,
            child: autoCard,
          ),
        ),
        childWhenDragging: Container(),
        child: autoCard,
      );
    });
  }

  Widget _buildOptionsRow({
    required String sortValue,
    required bool viewValue,
    required ValueChanged<String> onSortChanged,
    required ValueChanged<bool> onViewChanged,
    required ValueChanged<String> onSearchChanged,
    required TextEditingController searchController,
    required VoidCallback onAddFolder,
    required VoidCallback onAddItem,
    required bool isPathsView,
  }) {
    final useWideControls = _layoutMode == 'professional';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6.0),
      child: Column(children: [
        Row(
          children: [
            _buildViewButton(
              viewValue: viewValue,
              onViewChanged: onViewChanged,
              labeled: useWideControls,
            ),
            _buildSortButton(
              sortValue: sortValue,
              onSortChanged: onSortChanged,
              labeled: useWideControls,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSearchBar(
                isPathsView: isPathsView,
                onChanged: onSearchChanged,
                controller: searchController,
              ),
            ),
            const SizedBox(width: 14),
            _buildFolderButton(
              isPathsView: isPathsView,
              onAddFolder: onAddFolder,
              labeled: useWideControls,
              onDeleteFolder: () {
                showDialog(
                  context: this.context,
                  builder: (context) {
                    ColorScheme colorScheme = Theme.of(context).colorScheme;
                    return AlertDialog(
                      backgroundColor: colorScheme.surface,
                      surfaceTintColor: colorScheme.surfaceTint,
                      title: const Text('Delete Folder'),
                      content: SizedBox(
                        width: 400,
                        child: Text(
                          'Are you sure you want to delete the folder "${isPathsView ? _pathFolder : _autoFolder}"?\n\nThis will also delete all ${isPathsView ? "paths" : "autos"} within the folder. This cannot be undone.',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: Navigator.of(context).pop,
                          child: const Text('CANCEL'),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();

                            final folderToDelete =
                                isPathsView ? _pathFolder : _autoFolder;
                            if (folderToDelete != null) {
                              _deleteFolderPath(
                                  isPathsView: isPathsView,
                                  folder: folderToDelete);
                            }
                          },
                          child: const Text('DELETE'),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            _buildAddButton(
              isPathsView: isPathsView,
              onAddItem: onAddItem,
              labeled: useWideControls,
            ),
            const SizedBox(width: 8),
            _buildBulkDeleteButton(
              isPathsView: isPathsView,
              labeled: useWideControls,
            ),
            const SizedBox(width: 8),
          ],
        ),
        const SizedBox(height: 10),
      ]),
    );
  }

  Future<void> _showFile(String filePath) async {
    try {
      ProcessResult result;

      if (Platform.isMacOS) {
        result = await Process.run('open', ['-R', filePath]);
      } else if (Platform.isWindows) {
        result = await Process.run('explorer.exe', ['/select,$filePath']);
      } else if (Platform.isLinux) {
        result = await Process.run('xdg-open', [dirname(filePath)]);
      } else {
        return;
      }

      if (result.exitCode != 0 && mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          const SnackBar(content: Text('Failed to show file')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          const SnackBar(content: Text('Failed to show file')),
        );
      }
    }
  }

  Future<void> _exportPathPackage(PathPlannerPath path) async {
    final savePath = await getSaveLocation(
      suggestedName: '${path.name}.ppxpackage',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PathPlanner Package', extensions: ['ppxpackage']),
      ],
    );
    if (savePath == null) {
      return;
    }

    final package = {
      'format': 'ppxpackage',
      'version': 1,
      'packageType': 'path',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'path': _pathPackageEntry(path),
      'obstacles': [
        for (final boundary in widget.fieldProfile?.objectBoundaries() ??
            const <OptimizationBoundary>[])
          boundary.toJson(),
      ],
    };

    await fs.file(savePath.path).writeAsString(
          const JsonEncoder.withIndent('  ').convert(package),
        );

    if (mounted) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(content: Text('Exported ${path.name}.ppxpackage')),
      );
    }
  }

  Future<void> _exportAutoPackage(PathPlannerAuto auto) async {
    if (auto.choreoAuto) {
      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          const SnackBar(
            content:
                Text('Exporting Choreo autos is not supported in packages'),
          ),
        );
      }
      return;
    }

    final savePath = await getSaveLocation(
      suggestedName: '${auto.name}.ppxpackage',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PathPlanner Package', extensions: ['ppxpackage']),
      ],
    );
    if (savePath == null) {
      return;
    }

    final referencedPathNames = auto.getAllPathNames().toSet();
    final bundledPaths = [
      for (final pathName in referencedPathNames)
        if (_paths.firstWhereOrNull((p) => p.name == pathName) case final path?)
          _pathPackageEntry(path),
    ];

    final package = {
      'format': 'ppxpackage',
      'version': 1,
      'packageType': 'auto',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'auto': {
        'name': auto.name,
        'autoJson': auto.toJson(),
      },
      'paths': bundledPaths,
      'obstacles': [
        for (final boundary in widget.fieldProfile?.objectBoundaries() ??
            const <OptimizationBoundary>[])
          boundary.toJson(),
      ],
    };

    await fs.file(savePath.path).writeAsString(
          const JsonEncoder.withIndent('  ').convert(package),
        );

    if (mounted) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(content: Text('Exported ${auto.name}.ppxpackage')),
      );
    }
  }

  Map<String, dynamic> _pathPackageEntry(PathPlannerPath path) {
    return {
      'name': path.name,
      'pathJson': path.toJson(),
      'pathObjectsJson': {
        'version': pathObjectsFileVersion,
        'optimizationBoundaries': [
          for (final boundary in path.optimizationBoundaries) boundary.toJson(),
        ],
        'optimizationReferencePath': [
          for (final point in path.optimizationReferencePath)
            {
              'x': point.x,
              'y': point.y,
            },
        ],
        'optimizationReferenceAdherence':
            path.optimizationReferenceAdherence.clamp(0.0, 1.0),
      },
    };
  }

  Future<void> _importPackage() async {
    final packageFile = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PathPlanner Package', extensions: ['ppxpackage']),
      ],
    );
    if (packageFile == null) {
      return;
    }

    try {
      final raw = await fs.file(packageFile.path).readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['format'] != 'ppxpackage') {
        throw const FormatException('Invalid package format');
      }

      final type = decoded['packageType'];
      if (type == 'path') {
        await _importPathPackage(decoded);
      } else if (type == 'auto') {
        await _importAutoPackage(decoded);
      } else {
        throw const FormatException('Unknown package type');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          const SnackBar(content: Text('Failed to import package')),
        );
      }
    }
  }

  Future<void> _importPathPackage(Map<String, dynamic> package) async {
    final pathEntry = package['path'];
    if (pathEntry is! Map<String, dynamic>) {
      throw const FormatException('Path package payload is missing');
    }

    final incomingName = (pathEntry['name'] ?? '').toString().trim();
    if (incomingName.isEmpty) {
      throw const FormatException('Path name is missing');
    }

    final existingPathNames = _paths.map((e) => e.name).toSet();
    _PackageConflictAction action = _PackageConflictAction.overwrite;
    if (existingPathNames.contains(incomingName)) {
      final result = await _showImportConflictDialog([incomingName]);
      if (result == null || result == _PackageConflictAction.cancel) {
        return;
      }
      action = result;
    }

    final importedObstacles = _parseObstacleBoundaries(package['obstacles']);
    final targetName =
        _resolveImportedName(incomingName, existingPathNames, action);
    _removePathByName(targetName);

    final imported = _pathFromPackageEntry(
      pathEntry,
      targetName,
      importedObstacles,
    );
    imported.saveFile();

    if (!mounted) {
      return;
    }

    setState(() {
      _paths.add(imported);
      _sortPaths(_pathSortValue);
    });

    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(content: Text('Imported path ${imported.name}')),
    );
  }

  Future<void> _importAutoPackage(Map<String, dynamic> package) async {
    final autoEntry = package['auto'];
    if (autoEntry is! Map<String, dynamic>) {
      throw const FormatException('Auto package payload is missing');
    }

    final autoName = (autoEntry['name'] ?? '').toString().trim();
    if (autoName.isEmpty) {
      throw const FormatException('Auto name is missing');
    }

    final pathEntries = [
      for (final entry in (package['paths'] ?? []))
        if (entry is Map<String, dynamic>) entry,
    ];

    final importedObstacles = _parseObstacleBoundaries(package['obstacles']);
    final existingPathNames = _paths.map((e) => e.name).toSet();
    final existingAutoNames = _autos.map((e) => e.name).toSet();

    final conflicts = <String>[
      if (existingAutoNames.contains(autoName)) autoName,
      for (final entry in pathEntries)
        if (existingPathNames.contains((entry['name'] ?? '').toString()))
          (entry['name'] ?? '').toString(),
    ].where((name) => name.isNotEmpty).toSet().toList();

    _PackageConflictAction action = _PackageConflictAction.overwrite;
    if (conflicts.isNotEmpty) {
      final result = await _showImportConflictDialog(conflicts);
      if (result == null || result == _PackageConflictAction.cancel) {
        return;
      }
      action = result;
    }

    final pathRenameMap = <String, String>{};
    final importedPaths = <PathPlannerPath>[];

    for (final pathEntry in pathEntries) {
      final incomingName = (pathEntry['name'] ?? '').toString().trim();
      if (incomingName.isEmpty) {
        continue;
      }

      final targetName =
          _resolveImportedName(incomingName, existingPathNames, action);
      if (targetName != incomingName) {
        pathRenameMap[incomingName] = targetName;
      }

      _removePathByName(targetName);
      final imported =
          _pathFromPackageEntry(pathEntry, targetName, importedObstacles);
      imported.saveFile();
      importedPaths.add(imported);
      existingPathNames.add(targetName);
    }

    final targetAutoName =
        _resolveImportedName(autoName, existingAutoNames, action);
    _removeAutoByName(targetAutoName);

    final autoJson = autoEntry['autoJson'];
    if (autoJson is! Map<String, dynamic>) {
      throw const FormatException('Auto JSON is missing');
    }

    final importedAuto = PathPlannerAuto.fromJson(
      autoJson,
      targetAutoName,
      _autosDirectory.path,
      fs,
    );
    importedAuto.saveFile();

    for (final rename in pathRenameMap.entries) {
      importedAuto.updatePathName(rename.key, rename.value);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _paths.addAll(importedPaths);
      _sortPaths(_pathSortValue);
      _autos.add(importedAuto);
      _sortAutos(_autoSortValue);
    });

    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(content: Text('Imported auto ${importedAuto.name}')),
    );
  }

  List<OptimizationBoundary> _parseObstacleBoundaries(dynamic obstaclesJson) {
    final boundaries = <OptimizationBoundary>[];
    for (final entry in (obstaclesJson ?? [])) {
      if (entry is Map<String, dynamic>) {
        boundaries.add(OptimizationBoundary.fromJson(entry));
      }
    }
    return boundaries;
  }

  PathPlannerPath _pathFromPackageEntry(
    Map<String, dynamic> pathEntry,
    String targetName,
    List<OptimizationBoundary> importedObstacles,
  ) {
    final pathJson = pathEntry['pathJson'];
    if (pathJson is! Map<String, dynamic>) {
      throw const FormatException('Path JSON is missing');
    }

    final pathObjectsJson = pathEntry['pathObjectsJson'];
    final imported = PathPlannerPath.fromJson(
      pathJson,
      targetName,
      _pathsDirectory.path,
      fs,
    );

    if (pathObjectsJson is Map<String, dynamic>) {
      imported.optimizationBoundaries = [
        for (final boundaryJson
            in (pathObjectsJson['optimizationBoundaries'] ?? []))
          if (boundaryJson is Map<String, dynamic>)
            OptimizationBoundary.fromJson(boundaryJson),
      ];
      imported.optimizationReferencePath = [
        for (final pointJson
            in (pathObjectsJson['optimizationReferencePath'] ?? []))
          if (pointJson is Map<String, dynamic>)
            Translation2d(
              (pointJson['x'] ?? 0.0).toDouble(),
              (pointJson['y'] ?? 0.0).toDouble(),
            ),
      ];
      imported.optimizationReferenceAdherence =
          ((pathObjectsJson['optimizationReferenceAdherence'] ?? 0.5) as num)
              .toDouble()
              .clamp(0.0, 1.0);
    }

    for (final obstacle in importedObstacles) {
      if (!imported.optimizationBoundaries.contains(obstacle)) {
        imported.optimizationBoundaries.add(obstacle.clone());
      }
    }

    return imported;
  }

  String _resolveImportedName(
    String baseName,
    Set<String> existingNames,
    _PackageConflictAction action,
  ) {
    if (!existingNames.contains(baseName)) {
      return baseName;
    }

    if (action == _PackageConflictAction.makeCopy) {
      int copyNum = 1;
      String candidate = '$baseName-copy$copyNum';
      while (existingNames.contains(candidate)) {
        copyNum++;
        candidate = '$baseName-copy$copyNum';
      }
      return candidate;
    }

    return baseName;
  }

  Future<_PackageConflictAction?> _showImportConflictDialog(
      List<String> conflicts) {
    return showDialog<_PackageConflictAction>(
      context: this.context,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return AlertDialog(
          backgroundColor: colorScheme.surface,
          surfaceTintColor: colorScheme.surfaceTint,
          title: const Text('Import Conflict'),
          content: SizedBox(
            width: 420,
            child: Text(
              'The following items already exist:\n\n${conflicts.join(', ')}\n\nChoose how to continue.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_PackageConflictAction.cancel),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_PackageConflictAction.makeCopy),
              child: const Text('MAKE COPY'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_PackageConflictAction.overwrite),
              child: const Text('OVERWRITE'),
            ),
          ],
        );
      },
    );
  }

  void _removePathByName(String name) {
    final existing = _paths.firstWhereOrNull((path) => path.name == name);
    if (existing != null) {
      existing.deletePath();
      _paths.remove(existing);
    }
  }

  void _removeAutoByName(String name) {
    final existing = _autos.firstWhereOrNull((auto) => auto.name == name);
    if (existing != null) {
      existing.delete();
      _autos.remove(existing);
    }
  }

  Widget _buildViewButton({
    required bool viewValue,
    required ValueChanged<bool> onViewChanged,
    bool labeled = false,
  }) {
    return PopupMenuButton<bool>(
      initialValue: viewValue,
      tooltip: 'View options',
      icon: labeled
          ? null
          : Icon(viewValue ? Icons.view_list_rounded : Icons.grid_view_rounded),
      itemBuilder: (context) => const [
        PopupMenuItem(value: false, child: Text('Default')),
        PopupMenuItem(value: true, child: Text('Compact')),
      ],
      onSelected: onViewChanged,
      child: labeled
          ? _buildToolbarChip(
              buildContext: this.context,
              icon:
                  viewValue ? Icons.view_list_rounded : Icons.grid_view_rounded,
              label: viewValue ? 'Compact' : 'Default',
            )
          : null,
    );
  }

  Widget _buildSortButton({
    required String sortValue,
    required ValueChanged<String> onSortChanged,
    bool labeled = false,
  }) {
    return PopupMenuButton<String>(
      initialValue: sortValue,
      tooltip: 'Sort options',
      icon: labeled ? null : const Icon(Icons.sort_rounded),
      itemBuilder: (context) => _sortOptions(),
      onSelected: onSortChanged,
      child: labeled
          ? _buildToolbarChip(
              buildContext: this.context,
              icon: Icons.sort_rounded,
              label: 'Sort',
            )
          : null,
    );
  }

  Widget _buildFolderButton({
    required bool isPathsView,
    required VoidCallback onAddFolder,
    required VoidCallback onDeleteFolder,
    bool labeled = false,
  }) {
    final bool isRootFolder =
        isPathsView ? _pathFolder == null : _autoFolder == null;

    void onPressed() {
      if (isRootFolder) {
        onAddFolder();
      } else {
        onDeleteFolder();
      }
    }

    if (labeled) {
      return FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: Icon(isRootFolder
            ? Icons.create_new_folder_outlined
            : Icons.delete_forever_rounded),
        label: Text(isRootFolder ? 'New Folder' : 'Delete Folder'),
      );
    }

    return IconButton.filledTonal(
      icon: Icon(isRootFolder
          ? Icons.create_new_folder_outlined
          : Icons.delete_forever_rounded),
      tooltip: isRootFolder
          ? 'Add new folder'
          : isPathsView
              ? 'Delete path folder'
              : 'Delete auto folder',
      onPressed: onPressed,
    );
  }

  Widget _buildAddButton({
    required bool isPathsView,
    required VoidCallback onAddItem,
    bool labeled = false,
  }) {
    if (!isPathsView) {
      return Tooltip(
        message: 'Add new auto',
        waitDuration: const Duration(seconds: 1),
        child: labeled
            ? FilledButton.icon(
                key: _addAutoKey,
                onPressed: () {
                  if (_choreoPaths.isNotEmpty) {
                    final RenderBox renderBox = _addAutoKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    final Size size = renderBox.size;
                    final Offset offset = renderBox.localToGlobal(Offset.zero);
                    showMenu(
                      context: this.context,
                      position: RelativeRect.fromLTRB(
                        offset.dx,
                        offset.dy + size.height,
                        offset.dx + size.width,
                        offset.dy + size.height,
                      ),
                      items: [
                        PopupMenuItem(
                          child: const Text('New PathPlanner Auto'),
                          onTap: () => _createNewAuto(),
                        ),
                        PopupMenuItem(
                          child: const Text('New Choreo Auto'),
                          onTap: () => _createNewAuto(choreo: true),
                        ),
                      ],
                    );
                  } else {
                    _createNewAuto();
                  }
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('New Auto'),
              )
            : IconButton.filled(
                key: _addAutoKey,
                onPressed: () {
                  if (_choreoPaths.isNotEmpty) {
                    final RenderBox renderBox = _addAutoKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    final Size size = renderBox.size;
                    final Offset offset = renderBox.localToGlobal(Offset.zero);
                    showMenu(
                      context: this.context,
                      position: RelativeRect.fromLTRB(
                        offset.dx,
                        offset.dy + size.height,
                        offset.dx + size.width,
                        offset.dy + size.height,
                      ),
                      items: [
                        PopupMenuItem(
                          child: const Text('New PathPlanner Auto'),
                          onTap: () => _createNewAuto(),
                        ),
                        PopupMenuItem(
                          child: const Text('New Choreo Auto'),
                          onTap: () => _createNewAuto(choreo: true),
                        ),
                      ],
                    );
                  } else {
                    _createNewAuto();
                  }
                },
                icon: const Icon(Icons.add_rounded),
              ),
      );
    } else {
      if (labeled) {
        return Tooltip(
          message: 'Add new path',
          child: FilledButton.icon(
            icon: const Icon(Icons.add_rounded),
            onPressed: onAddItem,
            label: const Text('New Path'),
          ),
        );
      }

      return IconButton.filled(
        tooltip: 'Add new path',
        icon: const Icon(Icons.add_rounded),
        onPressed: onAddItem,
      );
    }
  }

  void _createNewAuto({bool choreo = false}) {
    List<String> autoNames = [];
    for (PathPlannerAuto auto in _autos) {
      autoNames.add(auto.name);
    }
    String autoName = 'New Auto';
    while (autoNames.contains(autoName)) {
      autoName = 'New $autoName';
    }

    setState(() {
      _autos.add(PathPlannerAuto.defaultAuto(
        autoDir: _autosDirectory.path,
        name: autoName,
        fs: fs,
        folder: _autoFolder,
        choreoAuto: choreo,
      ));
      _sortAutos(_autoSortValue);
    });
  }

  Widget _buildSearchBar({
    required bool isPathsView,
    required ValueChanged<String> onChanged,
    required TextEditingController controller,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: 'Search for ${isPathsView ? "Paths..." : "Autos..."}',
        prefixIcon: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Icon(Icons.search_rounded),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
      ),
      onChanged: (value) {
        // Debounce the search to avoid freezing
        Future.delayed(const Duration(milliseconds: 300), () {
          if (value == controller.text) {
            onChanged(value);
          }
        });
      },
    );
  }

  Widget _buildBulkDeleteButton({
    required bool isPathsView,
    bool labeled = false,
  }) {
    if (labeled) {
      return Tooltip(
        message: isPathsView ? 'Bulk delete paths' : 'Bulk delete autos',
        child: FilledButton.tonalIcon(
          icon: const Icon(Icons.checklist_rtl_rounded),
          onPressed: () => _showBulkDeleteDialog(isPathsView),
          label: const Text('Bulk Delete'),
        ),
      );
    }

    return IconButton.filledTonal(
      tooltip: isPathsView ? 'Bulk delete paths' : 'Bulk delete autos',
      icon: const Icon(Icons.checklist_rtl_rounded),
      onPressed: () => _showBulkDeleteDialog(isPathsView),
    );
  }

  Widget _buildToolbarChip({
    required BuildContext buildContext,
    required IconData icon,
    required String label,
  }) {
    final colorScheme = Theme.of(buildContext).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }

  Future<void> _showBulkDeleteDialog(bool isPathsView) async {
    final lowerSearch =
        (isPathsView ? _pathSearchQuery : _autoSearchQuery).toLowerCase();

    final pathCandidates = _paths
        .where((p) =>
            _matchesFolderFilter(p.folder, _pathFolder, _pathSearchQuery) &&
            p.name.toLowerCase().contains(lowerSearch))
        .toList();
    final autoCandidates = _autos
        .where((a) =>
            _matchesFolderFilter(a.folder, _autoFolder, _autoSearchQuery) &&
            a.name.toLowerCase().contains(lowerSearch))
        .toList();

    final candidates = isPathsView
        ? pathCandidates.map((e) => e.name).toList()
        : autoCandidates.map((e) => e.name).toList();

    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          SnackBar(
              content: Text(isPathsView
                  ? 'No paths to bulk delete in current view'
                  : 'No autos to bulk delete in current view')),
        );
      }
      return;
    }

    final selected = <String>{...candidates};

    final confirmed = await showDialog<bool>(
      context: this.context,
      builder: (dialogContext) {
        final ColorScheme colorScheme = Theme.of(dialogContext).colorScheme;

        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title:
                  Text(isPathsView ? 'Bulk Delete Paths' : 'Bulk Delete Autos'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () {
                              setStateDialog(() {
                                selected
                                  ..clear()
                                  ..addAll(candidates);
                              });
                            },
                            child: const Text('Select All'),
                          ),
                          TextButton(
                            onPressed: () {
                              setStateDialog(() {
                                selected.clear();
                              });
                            },
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView(
                        shrinkWrap: true,
                        children: candidates
                            .map(
                              (name) => CheckboxListTile(
                                value: selected.contains(name),
                                dense: true,
                                title: Text(name),
                                onChanged: (value) {
                                  setStateDialog(() {
                                    if (value ?? false) {
                                      selected.add(name);
                                    } else {
                                      selected.remove(name);
                                    }
                                  });
                                },
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Delete Selected'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true || selected.isEmpty) {
      return;
    }

    final typedConfirm = await _showTypedBulkDeleteConfirmation(
      isPathsView: isPathsView,
      selectedCount: selected.length,
    );

    if (typedConfirm != true) {
      return;
    }

    if (isPathsView) {
      for (final path in _paths.where((p) => selected.contains(p.name))) {
        path.deletePath();
      }

      setState(() {
        _paths.removeWhere((p) => selected.contains(p.name));
      });

      final allPathNames = _paths.map((e) => e.name).toList();
      for (PathPlannerAuto auto in _autos) {
        if (!auto.choreoAuto) {
          auto.handleMissingPaths(allPathNames);
        }
      }
    } else {
      for (final auto in _autos.where((a) => selected.contains(a.name))) {
        auto.delete();
      }

      setState(() {
        _autos.removeWhere((a) => selected.contains(a.name));
      });
    }
  }

  Future<bool?> _showTypedBulkDeleteConfirmation({
    required bool isPathsView,
    required int selectedCount,
  }) async {
    String typed = '';

    return showDialog<bool>(
      context: this.context,
      builder: (dialogContext) {
        final ColorScheme colorScheme = Theme.of(dialogContext).colorScheme;

        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final bool valid = typed.trim().toUpperCase() == 'DELETE';

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: const Text('Confirm Bulk Delete'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'You are about to delete $selectedCount ${isPathsView ? 'path file(s)' : 'auto file(s)'}.'),
                    const SizedBox(height: 8),
                    const Text('Type DELETE to confirm.'),
                    const SizedBox(height: 12),
                    TextField(
                      autofocus: true,
                      onChanged: (value) {
                        setStateDialog(() {
                          typed = value;
                        });
                      },
                      decoration: InputDecoration(
                        hintText: 'DELETE',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: valid
                      ? () => Navigator.of(dialogContext).pop(true)
                      : null,
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<PathPlannerPath> _getPathsFromNames(List<String> names) {
    List<PathPlannerPath> paths = [];
    for (String name in names) {
      List<PathPlannerPath> matched =
          _paths.where((path) => path.name == name).toList();
      if (matched.isNotEmpty) {
        paths.add(matched[0]);
      }
    }
    return paths;
  }

  List<ChoreoPath> _getChoreoPathsFromNames(List<String> names) {
    List<ChoreoPath> paths = [];
    for (String name in names) {
      List<ChoreoPath> matched =
          _choreoPaths.where((path) => path.name == name).toList();
      if (matched.isNotEmpty) {
        paths.add(matched[0]);
      }
    }
    return paths;
  }

  void _renameAuto(int autoIdx, String newName, BuildContext context) {
    List<String> autoNames = [];
    for (PathPlannerAuto auto in _autos) {
      autoNames.add(auto.name);
    }

    if (autoNames.contains(newName)) {
      showDialog(
          context: context,
          builder: (BuildContext context) {
            ColorScheme colorScheme = Theme.of(context).colorScheme;
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: const Text('Unable to Rename'),
              content: Text('The file "$newName.auto" already exists'),
              actions: [
                TextButton(
                  onPressed: Navigator.of(context).pop,
                  child: const Text('OK'),
                ),
              ],
            );
          });
    } else {
      setState(() {
        _autos[autoIdx].rename(newName);
        _sortAutos(_autoSortValue);
      });
    }
  }

  void _sortPaths(String sortOption) {
    // Get the latest sort option from shared preferences
    String latestSortOption =
        widget.prefs.getString(PrefsKeys.pathSortOption) ??
            Defaults.pathSortOption;

    switch (latestSortOption) {
      case 'recent':
        _paths.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        _pathFolders.sort((a, b) => a.compareTo(b));
        break;
      case 'nameDesc':
        _paths.sort((a, b) => b.name.compareTo(a.name));
        _pathFolders.sort((a, b) => b.compareTo(a));
        break;
      case 'nameAsc':
        _paths.sort((a, b) => a.name.compareTo(b.name));
        _pathFolders.sort((a, b) => a.compareTo(b));
        break;
      default:
        throw FormatException('Invalid sort value', sortOption);
    }
  }

  void _sortAutos(String sortOption) {
    switch (sortOption) {
      case 'recent':
        _autos.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        _autoFolders.sort((a, b) => a.compareTo(b));
        break;
      case 'nameDesc':
        _autos.sort((a, b) => b.name.compareTo(a.name));
        _autoFolders.sort((a, b) => b.compareTo(a));
        break;
      case 'nameAsc':
        _autos.sort((a, b) => a.name.compareTo(b.name));
        _autoFolders.sort((a, b) => a.compareTo(b));
        break;
      default:
        throw FormatException('Invalid sort value', sortOption);
    }
  }

  List<PopupMenuItem<String>> _sortOptions() {
    return const [
      PopupMenuItem(
        value: 'recent',
        child: Text('Recent'),
      ),
      PopupMenuItem(
        value: 'nameAsc',
        child: Text('Name Ascending'),
      ),
      PopupMenuItem(
        value: 'nameDesc',
        child: Text('Name Descending'),
      ),
    ];
  }

  PathConstraints _getDefaultConstraints() {
    return PathConstraints(
      maxVelocityMPS: widget.prefs.getDouble(PrefsKeys.defaultMaxVel) ??
          Defaults.defaultMaxVel,
      maxAccelerationMPSSq: widget.prefs.getDouble(PrefsKeys.defaultMaxAccel) ??
          Defaults.defaultMaxAccel,
      maxAngularVelocityDeg:
          widget.prefs.getDouble(PrefsKeys.defaultMaxAngVel) ??
              Defaults.defaultMaxAngVel,
      maxAngularAccelerationDeg:
          widget.prefs.getDouble(PrefsKeys.defaultMaxAngAccel) ??
              Defaults.defaultMaxAngAccel,
      nominalVoltage: widget.prefs.getDouble(PrefsKeys.defaultNominalVoltage) ??
          Defaults.defaultNominalVoltage,
    );
  }
}
