import unittest
from backend.inference import ModelService
from weather import mock_weather


class MarkdownPolicyTests(unittest.TestCase):
    def recommend(self, days, cost=2.31):
        stock={'product_id':'PROD_001','store_id':'STORE_01','category':'Produce',
               'snapshot_date':'2026-10-29','opening_inventory_units':40,
               'days_to_expiry':days,'standard_shelf_life_days':6,
               'delivery_lead_time_days':1,'pending_order_units':0,
               'base_price_usd':2.96,'cost_price_usd':cost}
        return ModelService.recommend(stock,7.49,mock_weather('2026-10-29'),0)

    def test_regular_discount_preserves_cost_floor(self):
        value=self.recommend(3)
        self.assertEqual(value['discount_type'],'REGULAR')
        self.assertEqual(value['discount_percent'],20)
        self.assertFalse(value['below_cost'])
        capped=self.recommend(3,2.90)
        self.assertEqual(capped['discount_percent'],2)
        self.assertGreaterEqual(capped['selling_price_usd'],2.90)
        blocked=self.recommend(3,3.00)
        self.assertEqual(blocked['discount_type'],'NONE')
        self.assertEqual(blocked['discount_percent'],0)

    def test_clearance_is_explicitly_below_cost(self):
        value=self.recommend(0)
        self.assertEqual(value['discount_type'],'CLEARANCE')
        self.assertEqual(value['selling_price_usd'],1.48)
        self.assertEqual(value['unit_margin_before_other_costs_usd'],-.83)
        self.assertTrue(value['clearance_acknowledgement_required'])
        expired=self.recommend(-1)
        self.assertFalse(expired['sale_allowed'])
        self.assertEqual(expired['discount_percent'],0)
