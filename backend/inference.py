"""Versioned adapter around the unchanged Phase 1–3 model and policy."""
import hashlib
import os
import sys
import math
from datetime import date, timedelta
from pathlib import Path

os.environ.setdefault('LOKY_MAX_CPU_COUNT', '4')
os.environ.setdefault('OMP_NUM_THREADS', '4')
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

import joblib
import pandas as pd
from predict_next_day import predict_from_history
from recommendation_engine import RecommendationInput, RulePolicy
from generator_aligned_engine import recommend_generator_aligned
from weather import OpenWeatherClient, WeatherError, mock_weather
from backend.branches import BRANCHES


class ModelService:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.metadata_path = self.directory / 'model_features.joblib'
        metadata = joblib.load(self.metadata_path)
        if metadata.get('recommendation_policy') != 'generator_aligned_v2':
            raise ValueError('Unsupported recommendation policy; validate the model adapter before switching.')
        self.model_path = self.directory / metadata['model_filename']
        # Only load trusted local artifacts. joblib is not a safe upload format.
        self.model_version, self.metadata_version = self.versions()

    def versions(self):
        return tuple(hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in (self.model_path, self.metadata_path))

    def predict(self, records, target_date, holiday, promotion):
        if self.versions() != (self.model_version, self.metadata_version):
            raise ValueError('Model artifacts changed; restart backend to load a consistent version.')
        history = pd.DataFrame(records)
        if history.empty:
            raise ValueError('No sales history available for this store.')
        history['date'] = pd.to_datetime(history.date, errors='raise')
        history = history.loc[history.date < pd.Timestamp(target_date)].sort_values(
            ['store_id', 'product_id', 'date']).reset_index(drop=True)
        if history.empty or history.date.max() + pd.Timedelta(days=1) != pd.Timestamp(target_date):
            raise ValueError('Forecast date must be the day after the latest history; missing days cannot be fabricated.')
        groups = history.groupby(['store_id', 'product_id'])
        if groups.size().min() < 29 or not groups.date.diff().dropna().eq(pd.Timedelta(days=1)).all():
            raise ValueError('Each product-store needs at least 29 consecutive history days.')
        result = predict_from_history(history, self.directory, holiday, promotion)
        if self.versions() != (self.model_version, self.metadata_version):
            raise ValueError('Model artifacts changed during inference; restart and retry.')
        if set(result.product_id) != set(history.product_id):
            raise ValueError('Incomplete product forecast.')
        return dict(zip(result.product_id, result.predicted_demand_units))

    @staticmethod
    def weather(request):
        target = request.snapshot_date.isoformat()
        if request.weather_mode == 'live':
            branch = BRANCHES.get(request.store_id)
            if branch is None:
                raise ValueError('No configured coordinates for this store.')
            return OpenWeatherClient().forecast(branch['lat'], branch['lon'], target)
        scenario = 'rainy' if request.scenario_id == 'rain-demo' else request.scenario_id
        if scenario == 'clear-demo':
            scenario = 'normal'
        return mock_weather(target, scenario)

    @staticmethod
    def recommend(snapshot, prediction, weather, promotion):
        lots=snapshot.get('lots')
        sellable=None
        usable=None
        days=snapshot['days_to_expiry']
        if lots is not None:
            today=date.fromisoformat(snapshot['snapshot_date'])
            sellable=[dict(lot) for lot in lots if lot['units']>0 and lot['expiry_date']>=str(today)]
            days=min(((date.fromisoformat(lot['expiry_date'])-today).days for lot in sellable),default=-1)
            projected=[dict(lot) for lot in sorted(sellable,key=lambda l:(l['expiry_date'],l['lot_key']))]
            for offset in range(snapshot['delivery_lead_time_days']):
                day=str(today+timedelta(days=offset))
                demand=float(prediction)
                for lot in projected:
                    if lot['expiry_date']<day:
                        lot['units']=0
                    used=min(lot['units'],demand)
                    lot['units']-=used
                    demand-=used
            arrival=str(today+timedelta(days=snapshot['delivery_lead_time_days']))
            usable=math.floor(sum(l['units'] for l in projected if l['expiry_date']>=arrival))
        item = RecommendationInput(
            product_id=snapshot['product_id'], store_id=snapshot['store_id'],
            category=snapshot['category'], decision_date=snapshot['snapshot_date'],
            predicted_demand_units=float(prediction),
            current_inventory_units=sum(l['units'] for l in sellable) if sellable is not None else snapshot['opening_inventory_units'],
            days_until_expiry=days,
            new_batch_shelf_life_days=snapshot['standard_shelf_life_days'],
            delivery_lead_time_days=snapshot['delivery_lead_time_days'],
            pending_order_units=snapshot['pending_order_units'],usable_inventory_override_units=usable)
        result = recommend_generator_aligned(item, weather)
        policy = RulePolicy()
        result['replenishment_explanation'] = {
            'arrival_date': str(date.fromisoformat(snapshot['snapshot_date']) + timedelta(days=item.delivery_lead_time_days)),
            'lead_time_days': item.delivery_lead_time_days,
            'review_period_days': policy.review_period_days,
            'buffer_units': float(prediction) * result['safety_stock_fraction'],
            'pending_order_units': item.pending_order_units,
            'rounding': 'Round the positive gap up to a whole unit, then apply the fresh-batch shelf-life cap.',
        }
        result['planned_campaign_promotion_active'] = promotion
        if lots is not None:
            threshold=1 if result['discount_action']=='FLASH_SALE' else 3
            offered=[l for l in sellable if (date.fromisoformat(l['expiry_date'])-today).days<=threshold] if result['discount_percent'] else []
            result['discount_eligible_units']=sum(l['units'] for l in offered)
            result['discount_batch_ids']=sorted({l['batch_id'] for l in offered})
            result['remove_expired_units']=sum(l['units'] for l in lots if l['expiry_date']<str(today))
            result['inventory_method']='FEFO_LOT_PROJECTION'
            result['lot_provenance']=sorted({l['source'] for l in lots})
            result['reasons'].append('LOT_LEVEL_INVENTORY_AT_ARRIVAL')
        # Keep expiry urgency separate from the permission to sell below cost.
        percent=result['discount_percent']
        discount_type='CLEARANCE' if result['discount_action']=='FLASH_SALE' else ('REGULAR' if percent else 'NONE')
        eligible_costs=[l['cost_price_usd'] for l in (lots or []) if l['batch_id'] in result.get('discount_batch_ids',[]) and l['units']>0]
        cost=max(eligible_costs,default=snapshot['cost_price_usd'])
        price=snapshot['base_price_usd']
        if discount_type=='REGULAR':
            cap=max(0,math.floor(100*(1-cost/price))) if price>0 else 0
            percent=min(percent,cap)
            if not percent:
                discount_type='NONE'
                result['discount_action']='PRICE_NORMAL'
                result['discount_eligible_units']=0
                result['discount_batch_ids']=[]
                result['reasons'].append('REGULAR_DISCOUNT_BLOCKED_BY_COST_FLOOR')
            elif percent!=result['discount_percent']:
                result['reasons'].append('REGULAR_DISCOUNT_CAPPED_AT_COST')
        sale_price=round(price*(1-percent/100),2)
        result.update(discount_percent=percent,discount_type=discount_type,
                      selling_price_usd=sale_price,unit_cost_reference_usd=cost,
                      unit_margin_before_other_costs_usd=round(sale_price-cost,4),
                      below_cost=bool(percent and sale_price<cost),
                      clearance_acknowledgement_required=bool(percent and sale_price<cost),
                      markdown_policy_version='regular-clearance-v1')
        return result
