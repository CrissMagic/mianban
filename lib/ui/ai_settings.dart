import 'package:flutter/material.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_models.dart';
import 'ai_usage.dart';
import 'widgets.dart';

Future<void> openAiSettings(BuildContext context, AiController controller) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AiSettingsScreen(controller: controller),
      ),
    );

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, required this.controller});
  final AiController controller;
  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final _endpoint = TextEditingController(),
      _key = TextEditingController(),
      _model = TextEditingController(),
      _version = TextEditingController();
  AiProvider _provider = AiProvider.openai;
  AiProtocol _protocol = AiProtocol.openaiResponses;
  AiAuth _auth = AiAuth.bearer;
  ModelCatalog _catalog = const ModelCatalog([]);
  Map<String, TokenPrice> _prices = {};
  String _error = '';
  bool _loading = true,
      _fetching = false,
      _saving = false,
      _manual = false,
      _showKey = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await widget.controller.initialize();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _select(widget.controller.activeProvider);
      _error = widget.controller.error;
    });
  }

  void _select(AiProvider provider) {
    final saved = widget.controller.profile(provider);
    _provider = provider;
    _endpoint.text = saved.baseUrl;
    _protocol = saved.protocol;
    _auth = saved.auth;
    _version.text = saved.anthropicVersion;
    _model.text = saved.model;
    _key.clear();
    _catalog = saved.catalog;
    _prices = Map.of(saved.prices);
    _manual =
        saved.model.isNotEmpty &&
        !saved.catalog.models.any((model) => model.id == saved.model);
    _showKey = false;
    _error = '';
  }

  AiProfile get _draft => widget.controller
      .profile(_provider)
      .copyWith(
        baseUrl: _endpoint.text.trim(),
        protocol: _protocol,
        auth: _auth,
        anthropicVersion: _version.text.trim(),
        model: _model.text.trim(),
        catalog: _catalog,
        prices: _prices,
      );

  void _invalidateEndpoint() {
    setState(() {
      _catalog = const ModelCatalog([]);
      _prices = {};
    });
  }

  Future<void> _fetchModels() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _fetching = true;
      _error = '';
    });
    try {
      final catalog = await widget.controller.fetchModels(_draft, _key.text);
      if (mounted) {
        setState(() {
          _catalog = catalog;
          _manual = false;
          if (!_catalog.models.any((model) => model.id == _model.text.trim())) {
            _model.clear();
          }
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = aiError(failure));
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await widget.controller.save(_draft, newKey: _key.text);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => _error = aiError(failure));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editPrice() async {
    final model = _model.text.trim();
    if (model.isEmpty) {
      setState(() => _error = '请先选择或填写型号');
      return;
    }
    final price = await showModalBottomSheet<TokenPrice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: cream,
      builder: (_) => TokenPriceEditor(
        model: model,
        price: _prices[model],
        currency:
            _provider == AiProvider.openai || _protocol == AiProtocol.anthropic
            ? 'USD'
            : 'CNY',
      ),
    );
    if (price != null && mounted) setState(() => _prices[model] = price);
  }

  @override
  void dispose() {
    for (final controller in [_endpoint, _key, _model, _version]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _fetching || _saving;
    final price = _prices[_model.text.trim()];
    final models = {for (final model in _catalog.models) model.id: model};
    if (_model.text.trim().isNotEmpty) {
      models.putIfAbsent(_model.text.trim(), () => AiModel(_model.text.trim()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型设置'),
        actions: [
          IconButton(
            tooltip: '调用记录',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AiUsageScreen(controller: widget.controller),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error.isNotEmpty)
                    ErrorNotice(
                      message: _error,
                      onDismiss: () => setState(() => _error = ''),
                    ),
                  Surface(
                    child: Column(
                      children: [
                        DropdownButtonFormField<AiProvider>(
                          key: ValueKey('provider-$_provider'),
                          initialValue: _provider,
                          decoration: const InputDecoration(labelText: '供应商'),
                          isExpanded: true,
                          items: AiProvider.values
                              .map(
                                (provider) => DropdownMenuItem(
                                  value: provider,
                                  child: Text(provider.label),
                                ),
                              )
                              .toList(),
                          onChanged: disabled
                              ? null
                              : (value) => setState(() => _select(value!)),
                        ),
                        const SizedBox(height: 20),
                        if (_provider == AiProvider.custom) ...[
                          DropdownButtonFormField<AiProtocol>(
                            key: ValueKey('protocol-$_protocol'),
                            initialValue: _protocol,
                            decoration: const InputDecoration(
                              labelText: '接口协议',
                            ),
                            isExpanded: true,
                            items: AiProtocol.values
                                .map(
                                  (protocol) => DropdownMenuItem(
                                    value: protocol,
                                    child: Text(
                                      protocol.label,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: disabled
                                ? null
                                : (value) => setState(() {
                                    _protocol = value!;
                                    _auth = value == AiProtocol.anthropic
                                        ? AiAuth.xApiKey
                                        : AiAuth.bearer;
                                    _catalog = const ModelCatalog([]);
                                  }),
                          ),
                          const SizedBox(height: 20),
                        ],
                        TextField(
                          key: const ValueKey('ai-endpoint'),
                          controller: _endpoint,
                          enabled: !disabled,
                          readOnly: ![
                            AiProvider.custom,
                            AiProvider.qwen,
                          ].contains(_provider),
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          onChanged: (_) => _invalidateEndpoint(),
                          decoration: InputDecoration(
                            labelText: 'API 基础地址',
                            hintText: 'https://example.com/v1',
                            suffixIcon: InfoButton(
                              title: 'API 基础地址',
                              body: _provider == AiProvider.qwen
                                  ? '百炼新端点包含业务空间 ID，例如 https://业务空间ID.cn-beijing.maas.aliyuncs.com/compatible-mode/v1。地址与密钥需属于同一地域。'
                                  : '填写协议版本所在的 HTTPS 基础路径，例如 /v1。请求时会追加 models、chat/completions、responses 或 messages。',
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          key: const ValueKey('ai-api-key'),
                          controller: _key,
                          enabled: !disabled,
                          obscureText: !_showKey,
                          autocorrect: false,
                          enableSuggestions: false,
                          onChanged: (_) =>
                              setState(() => _catalog = const ModelCatalog([])),
                          decoration: InputDecoration(
                            labelText: 'API Key',
                            hintText:
                                widget.controller
                                        .profile(_provider)
                                        .credentialId ==
                                    null
                                ? '填写个人 API Key'
                                : '已保存，输入可替换',
                            suffixIcon: IconButton(
                              tooltip: _showKey ? '隐藏密钥' : '显示密钥',
                              onPressed: () =>
                                  setState(() => _showKey = !_showKey),
                              icon: Icon(
                                _showKey
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (_provider == AiProvider.custom)
                          ExpansionTile(
                            title: const Text(
                              '鉴权',
                              style: TextStyle(fontSize: 14),
                            ),
                            tilePadding: EdgeInsets.zero,
                            children: [
                              DropdownButtonFormField<AiAuth>(
                                key: ValueKey('auth-$_auth'),
                                initialValue: _auth,
                                decoration: const InputDecoration(
                                  labelText: '密钥请求头',
                                ),
                                items: AiAuth.values
                                    .map(
                                      (auth) => DropdownMenuItem(
                                        value: auth,
                                        child: Text(auth.label),
                                      ),
                                    )
                                    .toList(),
                                onChanged: disabled
                                    ? null
                                    : (value) => setState(() {
                                        _auth = value!;
                                        _catalog = const ModelCatalog([]);
                                      }),
                              ),
                              if (_protocol == AiProtocol.anthropic)
                                TextField(
                                  controller: _version,
                                  enabled: !disabled,
                                  decoration: const InputDecoration(
                                    labelText: 'anthropic-version',
                                  ),
                                ),
                              const SizedBox(height: 12),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Surface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '模型',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            InfoButton(
                              title: '模型列表',
                              body:
                                  '获取后从接口返回的目录选择。${_catalog.models.isEmpty ? '' : '当前来源为${_catalog.source}。'}'
                                  '目录包含的型号需要具备所选协议的文本生成能力。GLM 列表端点不可用时读取智谱官方目录，账户权限由实际调用验证。',
                            ),
                            IconButton(
                              tooltip: _manual ? '切换模型列表' : '手动填写型号',
                              icon: Icon(
                                _manual ? Icons.list_alt : Icons.edit_outlined,
                              ),
                              onPressed: disabled
                                  ? null
                                  : () => setState(() => _manual = !_manual),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_manual)
                          TextField(
                            key: const ValueKey('ai-model-id'),
                            controller: _model,
                            enabled: !disabled,
                            autocorrect: false,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: '模型 ID',
                            ),
                          )
                        else
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'model-$_provider-${_model.text}-${_catalog.fetchedAt}',
                            ),
                            initialValue: _model.text.trim().isEmpty
                                ? null
                                : _model.text.trim(),
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '选择型号',
                            ),
                            items: models.values
                                .map(
                                  (model) => DropdownMenuItem(
                                    value: model.id,
                                    child: Text(
                                      model.label,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: disabled
                                ? null
                                : (value) =>
                                      setState(() => _model.text = value ?? ''),
                          ),
                        const SizedBox(height: 18),
                        PrimaryButton(
                          label: _fetching ? '正在获取' : '获取模型列表',
                          secondary: true,
                          icon: Icons.refresh_rounded,
                          onPressed: disabled ? null : _fetchModels,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Surface(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      title: Text(
                        price == null ? '设置模型单价' : '修改模型单价',
                        style: const TextStyle(fontSize: 15),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: disabled ? null : _editPrice,
                    ),
                  ),
                  const SizedBox(height: 24),
                  PrimaryButton(
                    label: _saving ? '正在保存' : '保存并使用',
                    icon: Icons.check_rounded,
                    onPressed: disabled ? null : _save,
                  ),
                  const SizedBox(height: 16),
                  const Center(
                    child: InfoButton(
                      title: '密钥与费用',
                      body:
                          'API Key 使用系统安全存储保存在设备中。模型分析会联网直连当前供应商。'
                          '费用按供应商返回的 Token 用量及各型号的配置单价估算。列表接口通常仅提供型号信息，单价可在这里按官方报价填写。'
                          '缺少用量、单价或缓存计费项时，调用费用标为待核对。历史记录保存调用当时的单价。',
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class TokenPriceEditor extends StatefulWidget {
  const TokenPriceEditor({
    super.key,
    required this.model,
    required this.currency,
    this.price,
  });
  final String model, currency;
  final TokenPrice? price;
  @override
  State<TokenPriceEditor> createState() => _TokenPriceEditorState();
}

class _TokenPriceEditorState extends State<TokenPriceEditor> {
  final _form = GlobalKey<FormState>();
  late final List<TextEditingController> _fields;
  late String _currency;
  @override
  void initState() {
    super.initState();
    final price = widget.price;
    _currency = price?.currency ?? widget.currency;
    _fields =
        [
              price?.input,
              price?.output,
              price?.cachedInput,
              price?.cacheWrite,
              price?.cacheWriteShort,
              price?.cacheWriteLong,
            ]
            .map(
              (value) => TextEditingController(
                text: value == null ? '' : TokenPrice.rateText(value),
              ),
            )
            .toList();
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  String? _validate(String? value, bool required) {
    if (value == null || value.trim().isEmpty) return required ? '请填写单价' : null;
    try {
      TokenPrice.parseRate(value);
      return null;
    } catch (_) {
      return '填写非负数字，最多6位小数';
    }
  }

  Widget _field(int index, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey('price-$index'),
      controller: _fields[index],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        suffixText: '$_currency / 百万Token',
      ),
      validator: (value) => _validate(value, index < 2),
    ),
  );

  void _save() {
    if (!_form.currentState!.validate()) return;
    final values = _fields
        .map(
          (field) => field.text.trim().isEmpty
              ? null
              : TokenPrice.parseRate(field.text),
        )
        .toList();
    Navigator.pop(
      context,
      TokenPrice(
        currency: _currency,
        input: values[0]!,
        output: values[1]!,
        cachedInput: values[2],
        cacheWrite: values[3],
        cacheWriteShort: values[4],
        cacheWriteLong: values[5],
        savedAt: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '模型单价',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const InfoButton(
                      title: '计费口径',
                      body:
                          '金额单位为每百万 Token 的所选币种。缓存读取、普通缓存写入及不同有效期的缓存写入分别计价。'
                          '短档对应 Anthropic 5分钟或 OpenAI 30分钟，长档对应 Anthropic 1小时或 OpenAI 12小时。'
                          '留空表示未知，0表示免费。思考 Token 已包含在输出用量中。费用为 Token 项估算，供应商账单还可能包含套餐、折扣及其他服务费用。',
                    ),
                  ],
                ),
                Text(
                  widget.model,
                  style: const TextStyle(fontSize: 13, color: muted),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  initialValue: _currency,
                  decoration: const InputDecoration(labelText: '币种'),
                  items: const [
                    DropdownMenuItem(value: 'CNY', child: Text('人民币 CNY')),
                    DropdownMenuItem(value: 'USD', child: Text('美元 USD')),
                  ],
                  onChanged: (value) => setState(() => _currency = value!),
                ),
                const SizedBox(height: 20),
                _field(0, '输入单价'),
                _field(1, '输出单价'),
                _field(2, '缓存读取单价'),
                ExpansionTile(
                  title: const Text('缓存写入单价', style: TextStyle(fontSize: 14)),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    _field(3, '普通写入'),
                    _field(4, '短档写入'),
                    _field(5, '长档写入'),
                  ],
                ),
                const SizedBox(height: 20),
                PrimaryButton(label: '应用单价', onPressed: _save),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
