import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/products_provider.dart';
import '../../../core/api/api_client.dart';
import 'package:dio/dio.dart';
import '../../../shared/utils/error_utils.dart';

class ProductFormScreen extends ConsumerStatefulWidget {
  final int? productId;
  const ProductFormScreen({super.key, this.productId});

  @override
  ConsumerState<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends ConsumerState<ProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  int? _categoryId;
  bool _isAvailable = true;
  bool _soldByWeight = false;
  int _sortOrder = 0;
  bool _loading = false;
  File? _pickedImage;
  String? _existingImageUrl;

  @override
  void initState() {
    super.initState();
    if (widget.productId != null) _loadProduct();
  }

  Future<void> _loadProduct() async {
    setState(() => _loading = true);
    try {
      final res = await ApiClient.instance.get('/products/${widget.productId}');
      final d = res.data as Map<String, dynamic>;
      _nameCtrl.text = d['name'] as String;
      _priceCtrl.text = d['price'].toString();
      _categoryId = d['category_id'] as int?;
      _isAvailable =
          (d['is_available'] as bool?) ??
          ((d['status'] as String?) == 'active');
      _soldByWeight = d['sold_by_weight'] as bool? ?? false;
      _sortOrder = (d['sort_order'] as num?)?.toInt() ?? 0;
      _existingImageUrl = ApiClient.resolveUrl(
        d['image_url'] as String? ?? d['image_path'] as String?,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked != null) setState(() => _pickedImage = File(picked.path));
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final isEdit = widget.productId != null;
      final url = isEdit ? '/products/${widget.productId}' : '/products';

      final body = {
        'name': _nameCtrl.text.trim(),
        'price': double.parse(_priceCtrl.text.trim()),
        'category_id': _categoryId,
        'status': _isAvailable ? 'active' : 'inactive',
        'sold_by_weight': _soldByWeight,
        'sort_order': _sortOrder,
      };

      int productId;
      if (isEdit) {
        await ApiClient.instance.put(url, data: body);
        productId = widget.productId!;
      } else {
        final res = await ApiClient.instance.post(url, data: body);
        productId = res.data['id'] as int;
      }

      if (_pickedImage != null) {
        final form = FormData.fromMap({
          'file': await MultipartFile.fromFile(_pickedImage!.path),
        });
        await ApiClient.instance.post('/products/$productId/image', data: form);
      }

      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(isEdit ? 'Product updated' : 'Product created'),
            ),
          );
        context.pop();
      }
      ref.invalidate(productsListProvider);
      ref.invalidate(productsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final isEdit = widget.productId != null;

    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Product' : 'New Product')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Image picker
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        height: 160,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.grey.shade100,
                          border: Border.all(color: Colors.grey.shade300),
                          image: _pickedImage != null
                              ? DecorationImage(
                                  image: FileImage(_pickedImage!),
                                  fit: BoxFit.cover,
                                )
                              : (_existingImageUrl != null
                                    ? DecorationImage(
                                        image: NetworkImage(_existingImageUrl!),
                                        fit: BoxFit.cover,
                                      )
                                    : null),
                        ),
                        child:
                            (_pickedImage == null && _existingImageUrl == null)
                            ? const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.add_photo_alternate_outlined,
                                    size: 40,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Tap to add image',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Product Name',
                      ),
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _priceCtrl,
                      decoration: InputDecoration(
                        labelText: _soldByWeight
                            ? 'Price per kg (RM)'
                            : 'Price (RM)',
                        prefixText: 'RM ',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Required';
                        if (double.tryParse(v) == null) return 'Invalid price';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    categoriesAsync.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) => Text(loadError(e)),
                      data: (cats) => DropdownButtonFormField<int?>(
                        initialValue: _categoryId,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                        ),
                        hint: const Text('None'),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('None'),
                          ),
                          ...cats.map(
                            (c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(c.name),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(() => _categoryId = v),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Sort Order',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        const Text(
                          'Lower = shown first',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 80,
                          child: TextFormField(
                            initialValue: _sortOrder.toString(),
                            decoration: const InputDecoration(isDense: true),
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            onChanged: (v) =>
                                _sortOrder = int.tryParse(v) ?? _sortOrder,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: const Text('Sold by weight'),
                      subtitle: const Text('Price = weight (kg) × unit price'),
                      secondary: const Icon(Icons.scale, color: Colors.teal),
                      value: _soldByWeight,
                      onChanged: (v) => setState(() => _soldByWeight = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile(
                      title: const Text('Available for sale'),
                      value: _isAvailable,
                      onChanged: (v) => setState(() => _isAvailable = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: Text(isEdit ? 'Save Changes' : 'Create Product'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
