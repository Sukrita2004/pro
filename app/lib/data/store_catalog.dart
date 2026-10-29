// Demo store IDs mapped to approximate real Central landmark locations.
const demoStores = [
  {
    'id': 'STORE_01',
    'name': 'FreshFlow Central Silom',
    'location': 'Bang Rak, Bangkok',
  },
  {
    'id': 'STORE_02',
    'name': 'FreshFlow Central Chidlom',
    'location': 'Pathum Wan, Bangkok',
  },
  {
    'id': 'STORE_03',
    'name': 'FreshFlow Central Ladprao',
    'location': 'Chatuchak, Bangkok',
  },
  {
    'id': 'STORE_04',
    'name': 'FreshFlow Central Bangna',
    'location': 'Bang Na, Bangkok',
  },
];
String storeName(String id) =>
    demoStores.firstWhere((s) => s['id'] == id)['name']!;
