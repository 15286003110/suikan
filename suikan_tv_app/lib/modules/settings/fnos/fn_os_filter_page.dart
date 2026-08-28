import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_models.dart';

/// 飞牛影视库筛选条件（基于列表接口可用字段）。
/// 注意：fnOS 列表接口不返回类型(genres)/国家/评分（仅在详情接口有），
/// 因此筛选只覆盖：分类、分辨率、动态范围、音频、语言、年份、状态、标题关键字。
class FnOsFilter {
  final Set<String> types; // {'Movie'} / {'TV'} / 空=全部
  final Set<String> resolutions;
  final Set<String> colorRanges;
  final Set<String> audioTypes;
  final Set<String> languages;
  final int? yearMin;
  final int? yearMax;
  final String status; // ''=全部, 匹配状态值
  final String keyword; // 标题关键字

  const FnOsFilter({
    this.types = const {},
    this.resolutions = const {},
    this.colorRanges = const {},
    this.audioTypes = const {},
    this.languages = const {},
    this.yearMin,
    this.yearMax,
    this.status = '',
    this.keyword = '',
  });

  static const FnOsFilter empty = FnOsFilter();

  bool get isActive =>
      types.isNotEmpty ||
      resolutions.isNotEmpty ||
      colorRanges.isNotEmpty ||
      audioTypes.isNotEmpty ||
      languages.isNotEmpty ||
      yearMin != null ||
      yearMax != null ||
      status.isNotEmpty ||
      keyword.isNotEmpty;

  int get activeCount {
    var n = 0;
    if (types.isNotEmpty) n++;
    if (resolutions.isNotEmpty) n++;
    if (colorRanges.isNotEmpty) n++;
    if (audioTypes.isNotEmpty) n++;
    if (languages.isNotEmpty) n++;
    if (yearMin != null || yearMax != null) n++;
    if (status.isNotEmpty) n++;
    if (keyword.isNotEmpty) n++;
    return n;
  }

  FnOsFilter copyWith({
    Set<String>? types,
    Set<String>? resolutions,
    Set<String>? colorRanges,
    Set<String>? audioTypes,
    Set<String>? languages,
    int? yearMin,
    int? yearMax,
    String? status,
    String? keyword,
    bool clearYearMin = false,
    bool clearYearMax = false,
    bool clearStatus = false,
  }) {
    return FnOsFilter(
      types: types ?? this.types,
      resolutions: resolutions ?? this.resolutions,
      colorRanges: colorRanges ?? this.colorRanges,
      audioTypes: audioTypes ?? this.audioTypes,
      languages: languages ?? this.languages,
      yearMin: clearYearMin ? null : (yearMin ?? this.yearMin),
      yearMax: clearYearMax ? null : (yearMax ?? this.yearMax),
      status: clearStatus ? '' : (status ?? this.status),
      keyword: keyword ?? this.keyword,
    );
  }

  static bool _matchTitle(String title, String kw) {
    if (kw.isEmpty) return true;
    return title.toLowerCase().contains(kw.toLowerCase());
  }

  bool matchesMovie(FnOsMovie m) {
    if (!_matchTitle(m.title, keyword)) return false;
    if (types.isNotEmpty) {
      final isTv = m.type == 'Series' || m.type == 'Season';
      if (isTv ? !types.contains('TV') : !types.contains('Movie')) return false;
    }
    if (resolutions.isNotEmpty &&
        !m.mediaStream.resolutions.any(resolutions.contains)) return false;
    if (colorRanges.isNotEmpty &&
        !m.mediaStream.colorRangeTypes.any(colorRanges.contains)) return false;
    if (audioTypes.isNotEmpty &&
        !m.mediaStream.audioTypes.any(audioTypes.contains)) return false;
    if (languages.isNotEmpty && !languages.contains(m.lan)) return false;
    final y = yearOf(m.releaseDate ?? '');
    if (yearMin != null && y != null && y < yearMin!) return false;
    if (yearMax != null && y != null && y > yearMax!) return false;
    if (status.isNotEmpty && (m.status ?? '') != status) return false;
    return true;
  }

  bool matchesSeries(FnOsTvSeries s) {
    if (!_matchTitle(s.title, keyword)) return false;
    if (types.isNotEmpty && !types.contains('TV')) return false;
    if (resolutions.isNotEmpty &&
        !s.mediaStream.resolutions.any(resolutions.contains)) return false;
    if (colorRanges.isNotEmpty &&
        !s.mediaStream.colorRangeTypes.any(colorRanges.contains)) return false;
    if (audioTypes.isNotEmpty &&
        !s.mediaStream.audioTypes.any(audioTypes.contains)) return false;
    if (languages.isNotEmpty && !languages.contains(s.lan)) return false;
    final y = yearOf(s.firstAirDate ?? '');
    if (yearMin != null && y != null && y < yearMin!) return false;
    if (yearMax != null && y != null && y > yearMax!) return false;
    if (status.isNotEmpty && (s.status ?? '') != status) return false;
    return true;
  }

  static int? yearOf(String date) {
    final m = RegExp(r'(19|20)\d{2}').firstMatch(date);
    return m == null ? null : int.parse(m.group(0)!);
  }
}

/// 影视库筛选页。
class FnOsFilterPage extends StatefulWidget {
  final FnOsFilter initial;
  final List<String> allResolutions;
  final List<String> allColorRanges;
  final List<String> allAudioTypes;
  final List<String> allLanguages;
  final List<int> allYears;
  final List<String> allStatuses;

  const FnOsFilterPage({
    Key? key,
    required this.initial,
    required this.allResolutions,
    required this.allColorRanges,
    required this.allAudioTypes,
    required this.allLanguages,
    required this.allYears,
    required this.allStatuses,
  }) : super(key: key);

  @override
  State<FnOsFilterPage> createState() => _FnOsFilterPageState();
}

class _FnOsFilterPageState extends State<FnOsFilterPage> {
  late FnOsFilter _filter;
  late final TextEditingController _kwController;

  @override
  void initState() {
    super.initState();
    _filter = widget.initial;
    _kwController = TextEditingController(text: widget.initial.keyword);
  }

  @override
  void dispose() {
    _kwController.dispose();
    super.dispose();
  }

  void _toggle(Set<String> set, String value) {
    setState(() {
      if (set.contains(value)) {
        set.remove(value);
      } else {
        set.add(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('筛选'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _filter = FnOsFilter.empty;
              _kwController.clear();
            }),
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: () {
              _filter = _filter.copyWith(keyword: _kwController.text.trim());
              Navigator.of(context).pop(_filter);
            },
            child: const Text('确定'),
          ),
        ],
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: _kwController,
            decoration: const InputDecoration(
              labelText: '标题关键字',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(keyword: v.trim())),
          ),
          _Section(
            title: '影视分类',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip('Movie', '电影', _filter.types, 'Movie'),
                _chip('TV', '电视剧', _filter.types, 'TV'),
              ],
            ),
          ),
          _Section(
            title: '分辨率',
            child: _wrapChips(
              widget.allResolutions,
              _filter.resolutions,
              (set, v) => _toggle(set, v),
            ),
          ),
          _Section(
            title: '视频动态范围',
            child: _wrapChips(
              widget.allColorRanges,
              _filter.colorRanges,
              (set, v) => _toggle(set, v),
            ),
          ),
          _Section(
            title: '音频规格',
            child: _wrapChips(
              widget.allAudioTypes,
              _filter.audioTypes,
              (set, v) => _toggle(set, v),
            ),
          ),
          _Section(
            title: '语言',
            child: _wrapChips(
              widget.allLanguages,
              _filter.languages,
              (set, v) => _toggle(set, v),
            ),
          ),
          _Section(
            title: '发行年份',
            child: _yearRow(widget.allYears),
          ),
          _Section(
            title: '匹配状态',
            child: _wrapChips(
              widget.allStatuses,
              {if (_filter.status.isNotEmpty) _filter.status},
              (set, v) => setState(() {
                if (set.contains(v)) {
                  _filter = _filter.copyWith(clearStatus: true);
                } else {
                  _filter = _filter.copyWith(status: v);
                }
              }),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _wrapChips(
    List<String> options,
    Set<String> selected,
    void Function(Set<String>, String) onToggle,
  ) {
    final theme = Theme.of(context);
    if (options.isEmpty) {
      return Text('暂无数据', style: theme.textTheme.bodySmall);
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options
          .map((v) => _chip(v, v, selected, v, onToggle: onToggle))
          .toList(),
    );
  }

  Widget _chip(
    String key,
    String label,
    Set<String> set,
    String value, {
    void Function(Set<String>, String)? onToggle,
  }) {
    final selected = set.contains(value);
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => (onToggle ?? _toggle)(set, value),
    );
  }

  Widget _yearRow(List<int> allYears) {
    final theme = Theme.of(context);
    if (allYears.isEmpty) {
      return Text('暂无数据', style: theme.textTheme.bodySmall);
    }
    final presets = <(String, int?, int?)>[
      ('全部', null, null),
      ('2020s', 2020, 2029),
      ('2010s', 2010, 2019),
      ('2000s', 2000, 2009),
      ('1990s', 1990, 1999),
      ('1980s', 1980, 1989),
      ('1970s', 1970, 1979),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: presets.map((p) {
        final selected = _filter.yearMin == p.$2 && _filter.yearMax == p.$3;
        return ChoiceChip(
          label: Text(p.$1),
          selected: selected,
          onSelected: (_) => setState(() {
            if (selected) {
              _filter =
                  _filter.copyWith(clearYearMin: true, clearYearMax: true);
            } else {
              _filter = _filter.copyWith(yearMin: p.$2, yearMax: p.$3);
            }
          }),
        );
      }).toList(),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
