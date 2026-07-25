import 'category.dart';
import '../api/api_client.dart';

class Product {
  final int id;
  final String name;
  final int? categoryId;
  final double price;
  final String? imageUrl;
  final bool isAvailable;
  final bool soldByWeight;
  final int sortOrder;
  final Category? category;

  const Product({
    required this.id,
    required this.name,
    this.categoryId,
    required this.price,
    this.imageUrl,
    required this.isAvailable,
    this.soldByWeight = false,
    this.sortOrder = 0,
    this.category,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        id: json['id'] as int,
        name: json['name'] as String,
        categoryId: json['category_id'] as int?,
        price: double.parse(json['price'].toString()),
        imageUrl: ApiClient.resolveUrl(json['image_path'] as String?),
        isAvailable: json['is_available'] as bool? ?? (json['status'] == 'active'),
        soldByWeight: json['sold_by_weight'] as bool? ?? false,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        category: json['category'] != null
            ? Category.fromJson(json['category'] as Map<String, dynamic>)
            : null,
      );

  Map<String, dynamic> toLocalDb() => {
        'id': id,
        'name': name,
        'category_id': categoryId,
        'price': price,
        'image_url': imageUrl,
        'is_available': isAvailable ? 1 : 0,
        'sort_order': sortOrder,
        'category_name': category?.name,
      };
}
