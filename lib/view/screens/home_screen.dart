import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:openscan/core/appRouter.dart';
import 'package:openscan/l10n/app_localizations.dart';
import 'package:openscan/core/data/database_helper.dart';
import 'package:openscan/core/data/document_naming.dart';
import 'package:openscan/core/data/file_operations.dart';
import 'package:openscan/core/models.dart';
import 'package:openscan/core/settings/app_settings.dart';
import 'package:openscan/core/theme/appTheme.dart';
import 'package:openscan/core/theme/os_colors.dart';
import 'package:openscan/core/theme/os_tokens.dart';
import 'package:openscan/core/theme/os_typography.dart';
import 'package:openscan/logic/cubit/directory_cubit.dart';
import 'package:openscan/view/Widgets/os/os_components.dart';
import 'package:openscan/view/Widgets/renameDialog.dart';
import 'package:openscan/view/screens/demo_screen.dart';
import 'package:openscan/view/screens/view_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's home: every session starts by finding or checking a document,
/// so the library grid lands first and the camera is one prominent tap away
/// rather than being the root screen itself.
class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DatabaseHelper database = DatabaseHelper();
  final FileOperations fileOperations = FileOperations();
  final QuickActions quickActions = QuickActions();
  final TextEditingController _searchController = TextEditingController();

  List<DirectoryOS> _documents = [];
  bool _loading = true;
  String _query = '';

  /// Selection lives here rather than in a cubit: it is per-screen state
  /// that never outlives this route, and keying it by directory path keeps
  /// it correct across a refresh that rebuilds every [DirectoryOS].
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _requestPermission();
    _showDemoOnFirstLaunch();
    _refresh();

    quickActions.initialize((String shortcutType) {
      _startScan(shortcutType);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Shortcut titles are the one piece of UI text the system renders for
    // us, so they have to be re-registered whenever the locale changes.
    // `type` stays an English id: it is what comes back through the
    // callback and is matched on, so translating it would break the
    // shortcut.
    final l10n = AppLocalizations.of(context)!;
    quickActions.setShortcutItems(<ShortcutItem>[
      ShortcutItem(
        type: 'Live Scan',
        localizedTitle: l10n.scan,
        icon: 'normal_scan',
      ),
      ShortcutItem(
        type: 'Import from Gallery',
        localizedTitle: l10n.import_from_gallery,
        icon: 'gallery_action',
      ),
    ]);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<bool> _requestPermission() async {
    // Camera only. Storage used to be requested alongside it, but the
    // manifest caps READ/WRITE_EXTERNAL_STORAGE at API 32/28 and every
    // path this app writes is either its own directory or handed over by
    // the system picker, so on anything newer the request was answered
    // "denied" without a dialog and the result was never read anyway.
    //
    // A permission request can fail outright rather than be denied — the
    // platform side refuses a second request while one is still running,
    // for instance — and an unhandled failure here would take the library
    // down with it on launch. Asking is worth a try; not getting an answer
    // is not worth a crash.
    try {
      return await Permission.camera.request().isGranted;
    } catch (e) {
      debugPrint('Could not request permissions: $e');
    }
    return false;
  }

  Future<void> _showDemoOnFirstLaunch() async {
    SharedPreferences preferences = await SharedPreferences.getInstance();
    final visited = preferences.getBool('alreadyVisited') ?? false;
    await preferences.setBool('alreadyVisited', true);
    if (!visited && mounted) {
      Navigator.of(context).pushNamed(AppRouter.demoScreen);
    }
  }

  Future<void> _refresh() async {
    final data = await database.getMasterData();
    final seen = <String>{};
    final documents = <DirectoryOS>[];

    for (var directory in data) {
      if (!seen.add(directory['dir_path'])) continue;
      documents.add(
        DirectoryOS(
          dirName: directory['dir_name'],
          dirPath: directory['dir_path'],
          created: DateTime.parse(directory['created']),
          imageCount: directory['image_count'],
          firstImgPath: directory['first_img_path'],
          lastModified: DateTime.parse(directory['last_modified']),
          newName: directory['new_name'],
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _documents = documents;
      _loading = false;
      // A document deleted elsewhere must not stay selected.
      _selected.removeWhere(
          (path) => !documents.any((doc) => doc.dirPath == path));
    });
  }

  String _titleOf(DirectoryOS doc) => doc.newName ?? doc.dirName;

  /// The grid's contents: sorted by the user's chosen order, then narrowed
  /// by the search field.
  List<DirectoryOS> get _visibleDocuments {
    final documents = [..._documents];
    switch (AppSettings.instance.sort) {
      case LibrarySort.lastModified:
        documents.sort((a, b) => (b.lastModified ?? b.created)
            .compareTo(a.lastModified ?? a.created));
        break;
      case LibrarySort.created:
        documents.sort((a, b) => b.created.compareTo(a.created));
        break;
      case LibrarySort.name:
        documents.sort((a, b) =>
            _titleOf(a).toLowerCase().compareTo(_titleOf(b).toLowerCase()));
        break;
      case LibrarySort.pageCount:
        documents.sort((a, b) => b.imageCount.compareTo(a.imageCount));
        break;
    }

    if (_query.isEmpty) return documents;
    final query = _query.toLowerCase();
    return documents
        .where((doc) => _titleOf(doc).toLowerCase().contains(query))
        .toList();
  }

  // <========================= Navigation =========================>

  void _openDocument(DirectoryOS doc) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BlocProvider<DirectoryCubit>(
          create: (context) => DirectoryCubit(
            dirName: doc.dirName,
            created: doc.created,
            dirPath: doc.dirPath,
            firstImgPath: doc.firstImgPath,
            imageCount: doc.imageCount,
            lastModified: doc.lastModified,
            newName: doc.newName,
            images: <ImageOS>[],
          )..getImageData(),
          lazy: false,
          child: ViewScreen(),
        ),
        settings: RouteSettings(name: AppRouter.viewScreen),
      ),
    ).whenComplete(_refresh);
  }

  /// Starts a capture session in a brand-new document and lands in
  /// Document detail when it finishes — never back in the library grid.
  /// The session is started by [ViewScreen] itself, which closes again if
  /// the user backs out of the camera without capturing anything, so a
  /// cancelled scan returns here rather than to an empty document.
  void _startScan(String scanType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BlocProvider<DirectoryCubit>(
          create: (context) => DirectoryCubit()..createDirectory(),
          child: ViewScreen(initialScan: scanType),
        ),
        settings: RouteSettings(name: AppRouter.viewScreen),
      ),
    ).whenComplete(_refresh);
  }

  // <========================= Selection actions =========================>

  void _toggleSelection(DirectoryOS doc) {
    setState(() {
      if (!_selected.remove(doc.dirPath)) _selected.add(doc.dirPath);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  void _selectAll() {
    setState(() {
      _selected.addAll(_visibleDocuments.map((doc) => doc.dirPath));
    });
  }

  List<DirectoryOS> get _selectedDocuments =>
      _documents.where((doc) => _selected.contains(doc.dirPath)).toList();

  Future<void> _deleteSelected() async {
    final documents = _selectedDocuments;
    Navigator.pop(context);

    for (final doc in documents) {
      final directory = Directory(doc.dirPath);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      await database.deleteDirectory(dirPath: doc.dirPath);
    }

    _clearSelection();
    await _refresh();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    OSSnack.success(
      context,
      documents.length == 1
          ? l10n.document_deleted
          : l10n.n_documents_deleted(documents.length),
    );
  }

  /// Exports every selected document as its own PDF, so a multi-select
  /// export produces one file per document rather than merging unrelated
  /// scans into one.
  Future<void> _exportSelected() async {
    final documents = _selectedDocuments;
    final messenger = ScaffoldMessenger.of(context);

    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ExportingDialog(),
    ));

    int exported = 0;
    for (final doc in documents) {
      final rows = await database.getImageData(doc.dirName);
      final images = <ImageOS>[
        for (final row in rows)
          ImageOS(idx: row['idx'], imgPath: row['img_path']),
      ];
      if (images.isEmpty) continue;
      final path = await fileOperations.saveToDevice(
        fileName: exportFileName(_titleOf(doc)),
        images: images,
      );
      if (path != null) exported++;
    }

    if (!mounted) return;
    Navigator.pop(context); // the progress dialog
    _clearSelection();

    messenger.hideCurrentSnackBar();
    final l10n = AppLocalizations.of(context)!;
    if (exported == documents.length) {
      OSSnack.success(context, l10n.saved_n_to_device(exported));
    } else {
      OSSnack.error(
          context, l10n.couldnt_export_n(documents.length - exported));
    }
  }

  // <========================= Sheets & menus =========================>

  void _openSortSheet() {
    final l10n = AppLocalizations.of(context)!;
    OSSheet.show(
      context: context,
      title: l10n.sort_order,
      builder: (sheetContext) {
        final os = sheetContext.os;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final sort in LibrarySort.values)
              OSSheetAction(
                icon: switch (sort) {
                  LibrarySort.lastModified => Icons.history_rounded,
                  LibrarySort.created => Icons.event_rounded,
                  LibrarySort.name => Icons.sort_by_alpha_rounded,
                  LibrarySort.pageCount => Icons.filter_none_rounded,
                },
                label: sort.label(l10n),
                trailing: AppSettings.instance.sort == sort
                    ? Icon(Icons.check_rounded, size: 20, color: os.accent)
                    : null,
                onTap: () async {
                  await AppSettings.instance.setSort(sort);
                  // Two different contexts, so two different checks: the
                  // sheet can be dismissed during the await while this
                  // screen is still very much alive, and an unguarded
                  // setState after that pop would fire on a dead State.
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (mounted) setState(() {});
                },
              ),
          ],
        );
      },
    );
  }

  void _openOverflow() {
    final l10n = AppLocalizations.of(context)!;
    OSSheet.show(
      context: context,
      title: 'DocScan',
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OSSheetAction(
            icon: Icons.settings_rounded,
            label: l10n.settings,
            onTap: () {
              Navigator.pop(sheetContext);
              Navigator.pushNamed(context, AppRouter.settingsScreen)
                  .then((_) => setState(() {}));
            },
          ),
          OSSheetAction(
            icon: Icons.school_rounded,
            label: l10n.tutorial,
            onTap: () {
              Navigator.pop(sheetContext);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DemoScreen(showSkip: false),
                ),
              );
            },
          ),
          OSSheetAction(
            icon: Icons.info_outline_rounded,
            label: l10n.about,
            onTap: () {
              Navigator.pop(sheetContext);
              Navigator.pushNamed(context, AppRouter.aboutScreen);
            },
          ),
        ],
      ),
    );
  }

  void _openDocumentMenu(DirectoryOS doc) {
    final l10n = AppLocalizations.of(context)!;
    OSSheet.show(
      context: context,
      title: _titleOf(doc),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OSSheetAction(
            icon: Icons.edit_rounded,
            label: l10n.rename,
            onTap: () {
              Navigator.pop(sheetContext);
              showDialog(
                context: context,
                builder: (_) => RenameDialog(
                  onConfirm: (_) => _refresh(),
                  docTableName: doc.dirName,
                  fileName: _titleOf(doc),
                ),
              );
            },
          ),
          OSSheetAction(
            icon: Icons.select_all_rounded,
            label: l10n.select,
            onTap: () {
              Navigator.pop(sheetContext);
              _toggleSelection(doc);
            },
          ),
          OSSheetAction(
            icon: Icons.delete_rounded,
            label: l10n.delete,
            destructive: true,
            onTap: () {
              Navigator.pop(sheetContext);
              _selected
                ..clear()
                ..add(doc.dirPath);
              _confirmDelete();
            },
          ),
        ],
      ),
    );
  }

  void _confirmDelete() {
    final count = _selected.length;
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => OSDialog(
        title: count == 1
            ? l10n.delete_document_q
            : l10n.delete_n_documents_q(count),
        message: l10n.cant_be_undone,
        confirmLabel: l10n.delete,
        destructive: true,
        onConfirm: _deleteSelected,
      ),
    ).then((_) {
      // Backing out of the dialog must not leave a document silently
      // selected from the long-press menu path above.
      if (mounted && _selected.length == 1) _clearSelection();
    });
  }

  // <========================= Build =========================>

  @override
  Widget build(BuildContext context) {
    final os = context.os;
    final documents = _visibleDocuments;

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        backgroundColor: os.surface,
        appBar: _selectionMode ? _selectionAppBar(os) : null,
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: os.accent,
            backgroundColor: os.surfaceContainer,
            child: _body(os, documents),
          ),
        ),
        bottomNavigationBar: _selectionMode ? _selectionBar(os) : _bottomNav(os),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                onPressed: () => _startScan('Live Scan'),
                backgroundColor: os.accent,
                foregroundColor: os.onAccent,
                elevation: 5,
                shape: const CircleBorder(),
                child: const Icon(Icons.camera_alt_rounded, size: 28),
              ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar(OSColors os) {
    final l10n = AppLocalizations.of(context)!;
    return AppBar(
      backgroundColor: os.onSurface,
      foregroundColor: os.surface,
      systemOverlayStyle:
          AppTheme.invertedOverlayStyle(os, Theme.of(context).brightness),
      leading: IconButton(
        icon: Icon(Icons.close_rounded, color: os.surface),
        onPressed: _clearSelection,
      ),
      title: Text(
        l10n.n_selected(_selected.length),
        style: OSTypography.subtitle.copyWith(color: os.surface),
      ),
      actions: [
        TextButton(
          onPressed: _selectAll,
          child: Text(
            l10n.select_all,
            style: OSTypography.label.copyWith(
              fontWeight: FontWeight.w700,
              color: os.accent,
            ),
          ),
        ),
        const SizedBox(width: OSSpace.xs),
      ],
    );
  }

  Widget _selectionBar(OSColors os) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          OSSpace.md + 2,
          OSSpace.xs,
          OSSpace.md + 2,
          OSSpace.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: OSButton(
                label: l10n.export,
                kind: OSButtonKind.tonal,
                expand: true,
                onPressed: _exportSelected,
              ),
            ),
            const SizedBox(width: OSSpace.sm),
            Expanded(
              child: OSButton(
                label: l10n.delete,
                kind: OSButtonKind.danger,
                expand: true,
                onPressed: _confirmDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(OSColors os, List<DirectoryOS> documents) {
    final l10n = AppLocalizations.of(context)!;
    if (_loading) return _skeleton(os);

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (!_selectionMode)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(26, 12, 26, 10),
              child: _searchField(os),
            ),
          ),
        if (_documents.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: OSEmptyState(
              icon: Icons.description_outlined,
              title: l10n.no_documents_yet,
              message: l10n.no_documents_body,
              action: OSButton(
                label: l10n.start_scanning,
                onPressed: () => _startScan('Live Scan'),
              ),
            ),
          )
        else if (documents.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: OSEmptyState(
              icon: Icons.search_off_rounded,
              title: l10n.no_results_for(_query),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(26, 4, 26, 100),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _DocumentCard(
                  document: documents[index],
                  title: _titleOf(documents[index]),
                  selected: _selected.contains(documents[index].dirPath),
                  selectionMode: _selectionMode,
                  onTap: () => _selectionMode
                      ? _toggleSelection(documents[index])
                      : _openDocument(documents[index]),
                  onLongPress: () => _selectionMode
                      ? _toggleSelection(documents[index])
                      : _openDocumentMenu(documents[index]),
                  onSelectionTap: () => _toggleSelection(documents[index]),
                ),
                childCount: documents.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _searchField(OSColors os) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: os.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (value) => setState(() => _query = value.trim()),
        style: OSTypography.body.copyWith(color: os.onSurface, fontSize: 18),
        decoration: InputDecoration(
          hintText: l10n.search_documents,
          hintStyle: OSTypography.body.copyWith(
            color: os.onSurfaceVariant,
            fontSize: 18,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 28,
            color: os.onSurfaceVariant,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 19),
        ),
      ),
    );
  }

  Widget _bottomNav(OSColors os) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: os.surface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 78,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(os, Icons.home_rounded, 'Home', true, () {}),
              _navItem(os, Icons.folder_outlined, 'Files', false, () {
                _searchController.clear();
                setState(() => _query = '');
              }),
              _navItem(os, Icons.grid_view_rounded, 'Tools', false, () {
                _openToolsSheet();
              }),
              _navItem(os, Icons.settings_outlined, l10n.settings, false, () {
                Navigator.pushNamed(context, AppRouter.settingsScreen)
                    .then((_) => setState(() {}));
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(
    OSColors os,
    IconData icon,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    final color = active ? os.accent : os.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 74,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 29),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              style: OSTypography.caption.copyWith(
                color: color,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openToolsSheet() {
    final l10n = AppLocalizations.of(context)!;
    OSSheet.show(
      context: context,
      title: 'Tools',
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OSSheetAction(
            icon: Icons.document_scanner_outlined,
            label: l10n.scan,
            onTap: () {
              Navigator.pop(sheetContext);
              _startScan('Live Scan');
            },
          ),
          OSSheetAction(
            icon: Icons.add_photo_alternate_outlined,
            label: l10n.import_from_gallery,
            onTap: () {
              Navigator.pop(sheetContext);
              _startScan('Import from Gallery');
            },
          ),
          OSSheetAction(
            icon: Icons.sort_rounded,
            label: l10n.sort,
            onTap: () {
              Navigator.pop(sheetContext);
              _openSortSheet();
            },
          ),
        ],
      ),
    );
  }

  Widget _skeleton(OSColors os) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(26, 90, 26, 100),
      itemCount: 7,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, __) => Container(
        height: 96,
        decoration: BoxDecoration(
          color: os.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  Widget _scrollable(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }
}

/// One library cell: page thumbnail, title, and "date · N pages".
class _DocumentCard extends StatelessWidget {
  const _DocumentCard({
    required this.document,
    required this.title,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectionTap,
  });

  final DirectoryOS document;
  final String title;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSelectionTap;

  String _date(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final value = document.lastModified ?? document.created;
    return DateFormat('dd/MM/yyyy HH:mm', locale).format(value);
  }

  @override
  Widget build(BuildContext context) {
    final os = context.os;
    final path = document.firstImgPath;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 82,
              height: 100,
              decoration: BoxDecoration(
                color: os.surfaceVariant,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: os.outline.withOpacity(.35)),
              ),
              clipBehavior: Clip.antiAlias,
              child: path != null && path.isNotEmpty && File(path).existsSync()
                  ? Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      errorBuilder: (_, __, ___) => _placeholder(os),
                    )
                  : _placeholder(os),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OSTypography.subtitle.copyWith(
                      color: os.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _date(context),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OSTypography.body.copyWith(
                            color: os.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.description_rounded,
                        size: 17,
                        color: os.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${document.imageCount}',
                        style: OSTypography.body.copyWith(
                          color: os.onSurfaceVariant,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            InkWell(
              onTap: onSelectionTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: AnimatedContainer(
                  duration: OSMotion.selection,
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: selected ? os.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: selected ? os.accent : os.onSurfaceVariant,
                      width: 2,
                    ),
                  ),
                  child: selected
                      ? Icon(Icons.check_rounded, size: 20, color: os.onAccent)
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(OSColors os) => ColoredBox(
        color: os.surfaceVariant,
        child: Icon(Icons.description_outlined, color: os.outline, size: 30),
      );
}

/// Barrier-blocking progress used while a multi-document export runs.
class _ExportingDialog extends StatelessWidget {
  const _ExportingDialog();

  @override
  Widget build(BuildContext context) {
    final os = context.os;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: os.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OSRadius.sheet),
      ),
      child: Padding(
        padding: const EdgeInsets.all(OSSpace.xl),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 20,
              width: 20,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: os.accent),
            ),
            const SizedBox(width: OSSpace.md),
            Text(l10n.exporting,
                style: OSTypography.body.copyWith(color: os.onSurface)),
          ],
        ),
      ),
    );
  }
}

/// The sort order's name, as shown in the sort sheet.
///
/// This lives here rather than beside the enum: [LibrarySort] is a stored
/// preference and has no business reaching for a [BuildContext], while the
/// label is only ever wanted by the sheet that draws it.
extension LibrarySortLabel on LibrarySort {
  String label(AppLocalizations l10n) {
    switch (this) {
      case LibrarySort.lastModified:
        return l10n.sort_last_modified;
      case LibrarySort.created:
        return l10n.sort_date_created;
      case LibrarySort.name:
        return l10n.sort_name;
      case LibrarySort.pageCount:
        return l10n.sort_page_count;
    }
  }
}
