import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String apiUrl =
    'https://script.google.com/macros/s/AKfycbyyn_npH0wGFZsd4WgxrYXK2OnUrWVeA5nEX4_qybbxg9y1slR4v8QexRJBUDqh7_YQ/exec';
const String cacheKey = 'push_limits_cached_data';
final currency = NumberFormat('#,##0', 'id_ID');
void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
      title: 'Push Limits Dashboard', debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true), home: const HomeScreen());
}

String? getVal(Map<String, dynamic> row, List<String> keys) {
  for (final k in keys) {
    for (final e in row.entries) {
      if (e.key.toLowerCase().replaceAll('_', ' ').contains(k.toLowerCase())) return e.value?.toString();
    }
  }
  return null;
}
double parseNum(String? v) => (v == null || v.isEmpty) ? 0 : (double.tryParse(v.replaceAll(',', '').trim()) ?? 0);
String fmtCurr(double v) => currency.format(v.round());
double calcGrowth(double c, double p) => p > 0 ? (c/p-1)*100 : (c > 0 ? 100 : 0);
String detectBiz(Map<String,dynamic> r) {
  final b = (getVal(r, ['business','bisnis','bussines','type']) ?? '').toUpperCase();
  return (b == 'PHG' || b == 'CHG') ? b : '';
}
const mNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
double targetYtd(Map<String,dynamic> r, int m) {
  final tF = parseNum(getVal(r, ['quota final','target final','target 2026','target tahun','target','quota']));
  final bln = int.tryParse(getVal(r, ['bulan','month','bln']) ?? '');
  if (bln != null) return bln <= m ? tF : 0;
  double tY = 0; bool found = false;
  for (var i = 0; i < 12; i++) {
    final v = parseNum(getVal(r, ['quota ${mNames[i].toLowerCase()}','target ${mNames[i].toLowerCase()}','sum of quota ${mNames[i].toLowerCase()}']));
    if (v > 0) { found = true; if (i+1 <= m) tY += v; }
  }
  if (!found && tF > 0) tY = tF * m / 12;
  return tY;
}

class ApiData {
  final List<Map<String,dynamic>> s25, s26, t26;
  ApiData(this.s25, this.s26, this.t26);
  Map<String,dynamic> toJson() => {'sales2025': s25, 'sales2026': s26, 'target2026': t26};
  static ApiData fromJson(Map<String,dynamic> j) {
    List<Map<String,dynamic>> toL(dynamic x) => (x as List).map((e) => Map<String,dynamic>.from(e as Map)).toList();
    return ApiData(toL(j['sales2025']), toL(j['sales2026']), toL(j['target2026']));
  }
}
Future<ApiData> fetchData() async {
  final j = jsonDecode((await http.get(Uri.parse(apiUrl))).body) as Map<String,dynamic>;
  final d = j['data'] as Map<String,dynamic>;
  List<Map<String,dynamic>> toL(dynamic x) => (x as List).map((e) => Map<String,dynamic>.from(e as Map)).toList();
  return ApiData(toL(d['sales2025']), toL(d['sales2026']), toL(d['target2026']));
}
Future<void> saveCache(ApiData d) async => (await SharedPreferences.getInstance()).setString(cacheKey, jsonEncode(d.toJson()));
Future<ApiData?> loadCache() async {
  final s = (await SharedPreferences.getInstance()).getString(cacheKey);
  if (s == null || s.isEmpty) return null;
  try { return ApiData.fromJson(jsonDecode(s) as Map<String,dynamic>); } catch (_) { return null; }
}

class Filters {
  int month; String biz, dist, search;
  Filters({this.month = 9, this.biz = 'ALL', this.dist = 'ALL', this.search = ''});
  bool pass(Map<String,dynamic> r) {
    if (biz != 'ALL' && detectBiz(r) != biz) return false;
    final d = (getVal(r, ['distributor']) ?? 'APL').toUpperCase();
    if (dist == 'APL' && !d.contains('APL') && !d.contains('ANUGERAH')) return false;
    if (dist == 'KFT' && (d.contains('APL') || d.contains('ANUGERAH'))) return false;
    return true;
  }
  Filters copyWith({int? month, String? biz, String? dist, String? search}) =>
    Filters(month: month ?? this.month, biz: biz ?? this.biz, dist: dist ?? this.dist, search: search ?? this.search);
}

class ColDef {
  final String label, key; final bool num, cur, pct;
  ColDef(this.label, this.key, {this.num = false, this.cur = false, this.pct = false});
}
final kCols = [
  ColDef('NAMA','name'),
  ColDef('2025','s25', num: true, cur: true),
  ColDef('2026','s26', num: true, cur: true),
  ColDef('TARGET','target', num: true, cur: true),
  ColDef('KONTRIBUSI','ach', num: true, pct: true),
  ColDef('GAP','gap', num: true, cur: true),
  ColDef('GROWTH','growth', num: true, pct: true),
];

Map<String,dynamic> _calc(double a, double b, double t, String n) =>
  {'name': n, 's25': a, 's26': b, 'target': t, 'growth': calcGrowth(b,a), 'ach': t>0?b/t*100:0.0, 'gap': b-t};

Map<String,dynamic> totalOf(List<Map<String,dynamic>> rows) {
  double a=0,b=0,t=0,g=0;
  for (final r in rows) { a += (r['s25'] as num?)?.toDouble()??0; b += (r['s26'] as num?)?.toDouble()??0; t += (r['target'] as num?)?.toDouble()??0; g += (r['gap'] as num?)?.toDouble()??0; }
  return _calc(a,b,t,'TOTAL');
}

List<Map<String,dynamic>> _group(ApiData d, Filters f, String Function(Map) key, {bool Function(Map)? extraFilter}) {
  final m = f.month; final map = <String, Map<String,double>>{};
  void add(List<Map<String,dynamic>> src, String kk) {
    for (final r in src) {
      if (!f.pass(r)) continue;
      if (extraFilter != null && !extraFilter(r)) continue;
      final bln = int.tryParse(getVal(r, ['bulan','month','bln']) ?? '') ?? 0;
      if (bln == 0 || bln > m) continue;
      final k = key(r);
      map.putIfAbsent(k, () => {'s25':0,'s26':0,'target':0});
      map[k]![kk] = map[k]![kk]! + parseNum(getVal(r, ['sum of sales','sales','value']));
    }
  }
  add(d.s25, 's25'); add(d.s26, 's26');
  for (final r in d.t26) {
    if (!f.pass(r)) continue;
    if (extraFilter != null && !extraFilter(r)) continue;
    final k = key(r);
    map.putIfAbsent(k, () => {'s25':0,'s26':0,'target':0});
    map[k]!['target'] = map[k]!['target']! + targetYtd(r, m);
  }
  return map.entries.where((e) => f.search.isEmpty || e.key.toUpperCase().contains(f.search.toUpperCase()))
    .map((e) => _calc(e.value['s25']!, e.value['s26']!, e.value['target']!, e.key)).toList();
}

List<Map<String,dynamic>> rSummary(ApiData d, Filters f) => _group(d, f, (r) => detectBiz(r).isEmpty ? 'ALL' : detectBiz(r));
List<Map<String,dynamic>> rBrand(ApiData d, Filters f) => _group(d, f, (r) => (getVal(r, ['brand','merek']) ?? 'UNKNOWN').toUpperCase());
List<Map<String,dynamic>> rDiv(ApiData d, Filters f) => _group(d, f, (r) => (getVal(r, ['division','divisi']) ?? 'UNKNOWN').toUpperCase());
List<Map<String,dynamic>> rProduct(ApiData d, Filters f) => _group(d, f, (r) => (getVal(r, ['product name','nama produk','material']) ?? 'UNKNOWN').toUpperCase());
List<Map<String,dynamic>> rOutlet(ApiData d, Filters f) => _group(d, f, (r) => (getVal(r, ['customer name','nama outlet','outlet','customer_name']) ?? 'UNKNOWN').toUpperCase());
List<Map<String,dynamic>> rReport(ApiData d, Filters f) => _group(d, f, (r) {
  final o = (getVal(r, ['customer name','nama outlet','outlet']) ?? 'UNKNOWN').toUpperCase();
  final p = (getVal(r, ['product name','nama produk']) ?? '').toUpperCase();
  return p.isNotEmpty ? '$o | $p' : o;
});
List<Map<String,dynamic>> rCity(ApiData d, Filters f) => _group(d, f, (r) => (getVal(r, ['kota','city','kabupaten','kota_kab']) ?? 'UNKNOWN').toUpperCase());
List<Map<String,dynamic>> rProv(ApiData d, Filters f) => _group(d, f, (r) => (getVal(r, ['provinsi','province']) ?? 'UNKNOWN').toUpperCase());
List<Map<String,dynamic>> rNpd(ApiData d, Filters f) => _group(d, f, (r) => (getVal(r, ['product name','nama produk']) ?? 'UNKNOWN').toUpperCase(),
  extraFilter: (r) => (getVal(r, ['remarks','remark','npd']) ?? '').toUpperCase().contains('NPD'));
List<Map<String,dynamic>> rAction(ApiData d, Filters f) => rBrand(d, f).where((e) => (e['gap'] as num) < 0).toList()
  ..sort((a,b) => (a['gap'] as num).compareTo(b['gap'] as num));

// Drilldown: OHT klik outlet → produk; PHT klik produk → outlet; Summary klik biz → division
List<Map<String,dynamic>> drilldown(ApiData d, Filters f, String menu, String rowName) {
  switch (menu) {
    case 'OHT': // row = outlet name → tampilkan produk
      return _group(d, f, (r) => (getVal(r, ['product name','nama produk']) ?? 'UNKNOWN').toUpperCase(),
        extraFilter: (r) => (getVal(r, ['customer name','nama outlet','outlet','customer_name']) ?? '').toUpperCase() == rowName);
    case 'PHT': // row = product name → tampilkan outlet/toko
      return _group(d, f, (r) => (getVal(r, ['customer name','nama outlet','outlet','customer_name']) ?? 'UNKNOWN').toUpperCase(),
        extraFilter: (r) => (getVal(r, ['product name','nama produk']) ?? '').toUpperCase() == rowName);
    case 'SUMMARY': // row = biz type → tampilkan division
      return _group(d, f, (r) => (getVal(r, ['division','divisi']) ?? 'UNKNOWN').toUpperCase(),
        extraFilter: (r) => detectBiz(r) == rowName);
    default:
      return [];
  }
}

const menus = ['SUMMARY','BRAND','DIVISION','REPORT SALES','PARETO','PROVINSI','PHT','OHT','BIG CITY','OUTLETS','NPD','FORECAST','KPI','ACTION BOARD'];

class SortableTable extends StatefulWidget {
  final List<ColDef> cols; final List<Map<String,dynamic>> rows; final Map<String,dynamic> total;
  final String menu; final ApiData data; final Filters f;
  const SortableTable({super.key, required this.cols, required this.rows, required this.total, required this.menu, required this.data, required this.f});
  @override
  State<SortableTable> createState() => _SortableTableState();
}
class _SortableTableState extends State<SortableTable> {
  String sk = 's25'; bool desc = true;
  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.rows]..sort((a,b) {
        final va = a[sk], vb = b[sk];
        if (va is String) return desc ? vb.compareTo(va) : va.compareTo(vb);
        final na = (va as num?)??0, nb = (vb as num?)??0;
        return desc ? nb.compareTo(na) : na.compareTo(nb);
      });
    final canDrill = widget.menu == 'OHT' || widget.menu == 'PHT' || widget.menu == 'SUMMARY';
    Widget cell(ColDef c, Map<String,dynamic> r, bool bold) {
      final v = r[c.key]; String txt; Color? col;
      if (c.pct) { final p = (v as num?)??0; txt = '${p.toStringAsFixed(1)}%'; col = (c.key=='growth'||c.key=='ach') ? (p < (c.key=='ach'?100:0) ? Colors.red : Colors.green) : null; }
      else if (c.cur) { final n = (v as num?)??0; txt = fmtCurr(n.toDouble()); col = c.key=='gap' ? (n<0?Colors.red:Colors.green) : null; }
      else txt = v?.toString() ?? '-';
      return Text(txt, style: TextStyle(fontSize: 11, fontWeight: bold?FontWeight.bold:FontWeight.normal, color: col),
        textAlign: c.num ? TextAlign.right : TextAlign.left, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    return SingleChildScrollView(scrollDirection: Axis.horizontal, child: SingleChildScrollView(child: DataTable(
      columnSpacing: 12, horizontalMargin: 8, dataRowMinHeight: 28, dataRowMaxHeight: 36, headingRowHeight: 36,
      columns: widget.cols.map((c) => DataColumn(label: Expanded(child: InkWell(
        onTap: () => setState(() { if (sk == c.key) desc = !desc; else { sk = c.key; desc = true; } }),
        child: Text('${c.label}${sk==c.key?(desc?' ↓':' ↑'):''}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      )), numeric: c.num)).toList(),
      rows: [
        DataRow(color: WidgetStateProperty.all(Colors.yellow.shade200), cells: [
          DataCell(Text('TOTAL (${widget.rows.length})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
          ...widget.cols.skip(1).map((c) => DataCell(cell(c, widget.total, true))),
        ]),
        ...sorted.map((r) => DataRow(
          onSelectChanged: canDrill ? (_) {
            final sub = drilldown(widget.data, widget.f, widget.menu, r['name']);
            if (sub.isEmpty) return;
            showDialog(context: context, builder: (ctx) => AlertDialog(
              title: Text('${r['name']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              content: SizedBox(width: double.maxFinite, child: SortableTable(cols: kCols, rows: sub, total: totalOf(sub), menu: '', data: widget.data, f: widget.f)),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup'))],
            ));
          } : null,
          cells: widget.cols.map((c) => DataCell(cell(c, r, false), showEditIcon: canDrill && c.key == 'name')).toList())),
      ],
    )));
  }
}

class KpiCards extends StatelessWidget {
  final ApiData data; final Filters f;
  const KpiCards({super.key, required this.data, required this.f});
  @override
  Widget build(BuildContext context) {
    final t = totalOf(rBrand(data, f));
    final s25 = (t['s25'] as num).toDouble(), s26 = (t['s26'] as num).toDouble(), tg = (t['target'] as num).toDouble();
    final ach = tg > 0 ? s26/tg*100 : 0, gr = calcGrowth(s26, s25), gap = s26 - tg;
    final cards = [
      ('SALES 2026 (YTD)', fmtCurr(s26), Colors.blue),
      ('SALES 2025 (YTD)', fmtCurr(s25), Colors.grey),
      ('TARGET YTD', fmtCurr(tg), Colors.orange),
      ('ACHIEVEMENT', '${ach.toStringAsFixed(1)}%', ach >= 100 ? Colors.green : Colors.red),
      ('GROWTH', '${gr.toStringAsFixed(1)}%', gr >= 0 ? Colors.green : Colors.red),
      ('GAP', fmtCurr(gap), gap >= 0 ? Colors.green : Colors.red),
    ];
    return GridView.count(crossAxisCount: 2, childAspectRatio: 2.2, padding: const EdgeInsets.all(8),
      children: cards.map((c) => Card(color: c.$3.withOpacity(0.1), child: Padding(padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(c.$1, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: c.$3)),
          const SizedBox(height: 4),
          Text(c.$2, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: c.$3)),
        ])))).toList());
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> {
  ApiData? _data; String? _err; int _tab = 0; Filters _f = Filters();
  bool _fromCache = false, _refreshing = false;
  @override
  void initState() { super.initState(); _init(); }
  Future<void> _init() async {
    final c = await loadCache();
    if (c != null && mounted) setState(() { _data = c; _fromCache = true; });
    _fetch();
  }
  Future<void> _fetch() async {
    if (!mounted) return;
    setState(() { _refreshing = true; _err = null; });
    try { final d = await fetchData(); await saveCache(d); if (mounted) setState(() { _data = d; _fromCache = false; _refreshing = false; }); }
    catch (e) { if (mounted) setState(() { _err = e.toString(); _refreshing = false; }); }
  }
  List<Map<String,dynamic>> _rows() {
    switch (menus[_tab]) {
      case 'SUMMARY': return rSummary(_data!, _f);
      case 'BRAND': case 'PARETO': return rBrand(_data!, _f);
      case 'DIVISION': return rDiv(_data!, _f);
      case 'REPORT SALES': return rReport(_data!, _f);
      case 'PROVINSI': return rProv(_data!, _f);
      case 'PHT': return rProduct(_data!, _f);
      case 'OHT': case 'OUTLETS': return rOutlet(_data!, _f);
      case 'BIG CITY': return rCity(_data!, _f);
      case 'NPD': return rNpd(_data!, _f);
      case 'ACTION BOARD': return rAction(_data!, _f);
      default: return rBrand(_data!, _f);
    }
  }
  @override
  Widget build(BuildContext context) {
    final isCard = menus[_tab] == 'KPI' || menus[_tab] == 'BUSINESS REVIEW';
    return Scaffold(
      appBar: AppBar(title: Text(menus[_tab], style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blue.shade900, foregroundColor: Colors.white,
        actions: [
          if (_refreshing) const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetch),
        ]),
      body: Column(children: [
        Container(width: double.infinity, color: _fromCache ? Colors.orange.shade50 : Colors.green.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(_refreshing ? 'Memperbarui data...' : (_fromCache ? 'Data tersimpan offline (tekan 🔄 untuk update)' : 'Data terbaru'),
            style: TextStyle(fontSize: 10, color: _fromCache ? Colors.orange.shade800 : Colors.green.shade800, fontWeight: FontWeight.bold))),
        SizedBox(height: 40, child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: menus.length,
          itemBuilder: (ctx, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            child: ChoiceChip(label: Text(menus[i], style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: _tab==i?Colors.white:Colors.black87)),
              selected: _tab == i, selectedColor: Colors.blue.shade900, backgroundColor: Colors.grey.shade200,
              onSelected: (_) => setState(() => _tab = i))))),
        Padding(padding: const EdgeInsets.all(8), child: FilterBar(f: _f, onChanged: (v) => setState(() => _f = v))),
        Expanded(child: _err != null && _data == null
          ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text('Gagal ambil data:\n$_err', textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))))
          : _data == null ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Mengambil data...')]))
          : isCard ? KpiCards(data: _data!, f: _f)
          : SortableTable(cols: kCols, rows: _rows(), total: totalOf(_rows()), menu: menus[_tab], data: _data!, f: _f)),
      ]),
    );
  }
}

class FilterBar extends StatelessWidget {
  final Filters f; final ValueChanged<Filters> onChanged;
  const FilterBar({super.key, required this.f, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    dd(List<String> items, String val, ValueChanged<String?> onCh) => DropdownButton<String>(
      value: val, isDense: true, underline: const SizedBox(),
      items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 12)))).toList(), onChanged: onCh);
    return Wrap(spacing: 8, runSpacing: 6, children: [
      dd(List.generate(12, (i) => 'Bulan ${i+1}'), 'Bulan ${f.month}', (v) => onChanged(Filters(month: int.parse(v!.split(' ')[1]), biz: f.biz, dist: f.dist, search: f.search))),
      dd(['ALL','PHG','CHG'], f.biz, (v) => onChanged(Filters(month: f.month, biz: v!, dist: f.dist, search: f.search))),
      dd(['ALL','APL','KFT'], f.dist, (v) => onChanged(Filters(month: f.month, biz: f.biz, dist: v!, search: f.search))),
      SizedBox(width: 150, height: 32, child: TextField(style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(isDense: true, hintText: 'Cari...', border: OutlineInputBorder()),
        onChanged: (v) => onChanged(Filters(month: f.month, biz: f.biz, dist: f.dist, search: v)))),
    ]);
  }
}
