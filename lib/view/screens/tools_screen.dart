import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:openscan/core/appRouter.dart';
import 'package:openscan/core/theme/os_colors.dart';
import 'package:openscan/core/theme/os_typography.dart';
import 'package:openscan/logic/cubit/directory_cubit.dart';
import 'package:openscan/view/screens/view_screen.dart';
import 'package:openscan/view/screens/tools/extract_text_screen.dart';
import 'package:openscan/view/screens/tools/scan_code_screen.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final ScrollController _scrollController = ScrollController();
  final Map<_ToolSection, GlobalKey> _sectionKeys = {
    _ToolSection.scan: GlobalKey(),
    _ToolSection.convert: GlobalKey(),
    _ToolSection.edit: GlobalKey(),
    _ToolSection.utilities: GlobalKey(),
  };

  _ToolSection _selectedSection = _ToolSection.scan;

  static const _scanTools = <_ToolItem>[
    _ToolItem('ID Cards', Icons.badge_outlined, _ToolTone.teal, _ToolAction.idCard),
    _ToolItem('Extract Text', Icons.text_fields_rounded, _ToolTone.teal, _ToolAction.extractText),
    _ToolItem('Passport\nPhoto Maker', Icons.person_rounded, _ToolTone.blue, _ToolAction.passportPhoto),
    _ToolItem('Photo\nTranslation', Icons.translate_rounded, _ToolTone.purple, _ToolAction.photoTranslation),
    _ToolItem('Scan Code', Icons.qr_code_scanner_rounded, _ToolTone.teal, _ToolAction.scanCode),
  ];

  static const _convertTools = <_ToolItem>[
    _ToolItem('Merge PDF', Icons.call_merge_rounded, _ToolTone.teal, _ToolAction.mergePdf),
    _ToolItem('Image to PDF', Icons.image_rounded, _ToolTone.green, _ToolAction.imageToPdf),
    _ToolItem('Text to PDF', Icons.article_rounded, _ToolTone.blue, _ToolAction.textToPdf),
    _ToolItem('To Word', Icons.description_rounded, _ToolTone.indigo, _ToolAction.toWord),
    _ToolItem('To Excel', Icons.table_chart_rounded, _ToolTone.green, _ToolAction.toExcel),
    _ToolItem('PDF to\nImages', Icons.collections_rounded, _ToolTone.teal, _ToolAction.pdfToImages),
    _ToolItem('PDF to Long\nImage', Icons.image_outlined, _ToolTone.blue, _ToolAction.pdfToLongImage),
  ];

  static const _editTools = <_ToolItem>[
    _ToolItem('OpenCV Crop', Icons.crop_free_rounded, _ToolTone.teal, _ToolAction.crop, isNew: true),
    _ToolItem('BG Remover', Icons.auto_fix_high_rounded, _ToolTone.purple, _ToolAction.bgRemover, isNew: true),
    _ToolItem('Image Resizer', Icons.crop_rounded, _ToolTone.pink, _ToolAction.imageResizer),
    _ToolItem('Split PDF', Icons.call_split_rounded, _ToolTone.blue, _ToolAction.splitPdf),
    _ToolItem('Sign', Icons.draw_rounded, _ToolTone.teal, _ToolAction.sign),
    _ToolItem('Add\nWatermark', Icons.branding_watermark_rounded, _ToolTone.blue, _ToolAction.watermark),
    _ToolItem('Extract PDF\nPages', Icons.call_split_rounded, _ToolTone.blue, _ToolAction.extractPages),
    _ToolItem('Reorder\nPages', Icons.swap_vert_rounded, _ToolTone.purple, _ToolAction.reorderPages),
    _ToolItem('Rotate PDF', Icons.rotate_right_rounded, _ToolTone.purple, _ToolAction.rotatePdf),
    _ToolItem('Lock', Icons.lock_rounded, _ToolTone.green, _ToolAction.lockPdf),
    _ToolItem('Compress', Icons.compress_rounded, _ToolTone.blue, _ToolAction.compress),
  ];

  static const _utilityTools = <_ToolItem>[
    _ToolItem('AI Chat', Icons.psychology_rounded, _ToolTone.teal, _ToolAction.aiChat),
    _ToolItem('Print', Icons.print_rounded, _ToolTone.teal, _ToolAction.print),
    _ToolItem('Create QR\nCode', Icons.qr_code_rounded, _ToolTone.teal, _ToolAction.createQr),
  ];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _goToSection(_ToolSection section) {
    setState(() => _selectedSection = section);
    final context = _sectionKeys[section]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.04,
      );
    }
  }

  void _startScan({bool gallery = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BlocProvider<DirectoryCubit>(
          create: (_) => DirectoryCubit()..createDirectory(),
          child: ViewScreen(
            initialScan: gallery ? 'Import from Gallery' : 'Live Scan',
          ),
        ),
      ),
    );
  }

  void _handleTool(_ToolItem item) {
    switch (item.action) {
      case _ToolAction.idCard:
        _startScan();
        break;
      case _ToolAction.extractText:
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ExtractTextScreen()));
        break;
      case _ToolAction.scanCode:
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanCodeScreen()));
        break;
      case _ToolAction.imageToPdf:
        _startScan(gallery: true);
        break;
      case _ToolAction.crop:
        _startScan(gallery: true);
        break;
      default:
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('${item.label.replaceAll('\n', ' ')} will be connected in the next tools phase.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final os = context.os;
    return Scaffold(
      backgroundColor: os.surface,
      body: SafeArea(
        child: Column(
          children: [
            _header(os),
            _tabs(os),
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _section(os, _ToolSection.scan, 'Scan', _scanTools),
                    _section(os, _ToolSection.convert, 'Convert', _convertTools),
                    _section(os, _ToolSection.edit, 'Edit', _editTools),
                    _section(os, _ToolSection.utilities, 'Utilities', _utilityTools),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _bottomNavigation(os),
    );
  }

  Widget _header(OSColors os) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 24, 24, 16),
      child: Row(
        children: [
          Text(
            'Tools',
            style: OSTypography.display.copyWith(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: os.onSurface,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Search tools',
            onPressed: _showSearch,
            icon: Icon(Icons.search_rounded, size: 32, color: os.onSurface),
          ),
        ],
      ),
    );
  }

  Widget _tabs(OSColors os) {
    return SizedBox(
      height: 58,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: _ToolSection.values.map((section) {
          final selected = _selectedSection == section;
          return InkWell(
            onTap: () => _goToSection(section),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _sectionLabel(section),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected ? os.onSurface : os.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 7),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: selected ? 32 : 0,
                    height: 3,
                    decoration: BoxDecoration(
                      color: os.accent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _section(OSColors os, _ToolSection section, String title, List<_ToolItem> items) {
    return Container(
      key: _sectionKeys[section],
      margin: const EdgeInsets.only(top: 18, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
              color: os.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisExtent: 145,
              crossAxisSpacing: 10,
              mainAxisSpacing: 8,
            ),
            itemBuilder: (_, index) => _toolTile(os, items[index]),
          ),
        ],
      ),
    );
  }

  Widget _toolTile(OSColors os, _ToolItem item) {
    final colors = _tone(item.tone, os);
    return InkWell(
      onTap: () => _handleTool(item),
      borderRadius: BorderRadius.circular(18),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.$1,
                  border: Border.all(color: colors.$2.withValues(alpha: .24)),
                ),
                child: Icon(item.icon, color: colors.$2, size: 34),
              ),
              if (item.isNew)
                Positioned(
                  right: -9,
                  top: -3,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF04444),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Text('New', style: TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            item.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15.5, height: 1.15, color: os.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  (Color, Color) _tone(_ToolTone tone, OSColors os) {
    switch (tone) {
      case _ToolTone.teal:
        return (const Color(0xFFE0F5F2), const Color(0xFF17B8A3));
      case _ToolTone.green:
        return (const Color(0xFFE5F6EA), const Color(0xFF11AD5C));
      case _ToolTone.blue:
        return (const Color(0xFFE4F0FF), const Color(0xFF3184ED));
      case _ToolTone.indigo:
        return (const Color(0xFFE7ECFF), const Color(0xFF3D67E8));
      case _ToolTone.purple:
        return (const Color(0xFFEEE9FF), const Color(0xFF7458E7));
      case _ToolTone.pink:
        return (const Color(0xFFFFE7F1), const Color(0xFFE54A99));
    }
  }

  Widget _bottomNavigation(OSColors os) {
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
              _navItem(os, Icons.home_outlined, 'Home', false, () {
                Navigator.popUntil(context, (route) => route.isFirst);
              }),
              _navItem(os, Icons.folder_outlined, 'Files', false, () {
                Navigator.popUntil(context, (route) => route.isFirst);
              }),
              _navItem(os, Icons.grid_view_rounded, 'Tools', true, () {}),
              _navItem(os, Icons.settings_outlined, 'Settings', false, () {
                Navigator.pushNamed(context, AppRouter.settingsScreen);
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(OSColors os, IconData icon, String label, bool active, VoidCallback onTap) {
    final color = active ? os.accent : os.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 76,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 29, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSearch() async {
    final all = <_ToolItem>[..._scanTools, ..._convertTools, ..._editTools, ..._utilityTools];
    await showSearch<_ToolItem?>(
      context: context,
      delegate: _ToolSearchDelegate(all, _handleTool),
    );
  }

  String _sectionLabel(_ToolSection section) {
    switch (section) {
      case _ToolSection.scan: return 'Scan';
      case _ToolSection.convert: return 'Convert';
      case _ToolSection.edit: return 'Edit';
      case _ToolSection.utilities: return 'Utilities';
    }
  }
}

class _ToolSearchDelegate extends SearchDelegate<_ToolItem?> {
  _ToolSearchDelegate(this.items, this.onOpen);
  final List<_ToolItem> items;
  final ValueChanged<_ToolItem> onOpen;

  @override
  String get searchFieldLabel => 'Search tools';

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(icon: const Icon(Icons.clear_rounded), onPressed: () => query = ''),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final q = query.trim().toLowerCase();
    final result = q.isEmpty
        ? items
        : items.where((e) => e.label.replaceAll('\n', ' ').toLowerCase().contains(q)).toList();
    return ListView.builder(
      itemCount: result.length,
      itemBuilder: (_, i) {
        final item = result[i];
        return ListTile(
          leading: Icon(item.icon),
          title: Text(item.label.replaceAll('\n', ' ')),
          onTap: () {
            close(context, item);
            onOpen(item);
          },
        );
      },
    );
  }
}

enum _ToolSection { scan, convert, edit, utilities }
enum _ToolTone { teal, green, blue, indigo, purple, pink }
enum _ToolAction {
  idCard, extractText, passportPhoto, photoTranslation, scanCode,
  mergePdf, imageToPdf, textToPdf, toWord, toExcel, pdfToImages, pdfToLongImage,
  crop, bgRemover, imageResizer, splitPdf, sign, watermark, extractPages,
  reorderPages, rotatePdf, lockPdf, compress, aiChat, print, createQr,
}

class _ToolItem {
  const _ToolItem(this.label, this.icon, this.tone, this.action, {this.isNew = false});
  final String label;
  final IconData icon;
  final _ToolTone tone;
  final _ToolAction action;
  final bool isNew;
}
