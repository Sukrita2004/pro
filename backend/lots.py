"""Daily lot balances and deterministic FEFO, within caller's transaction."""
import json
from datetime import date, timedelta
from backend.storage import encode


def read(connection, snapshot_id):
    return [dict(r) for r in connection.execute(
        'SELECT lot_key,batch_id,expiry_date,units,cost_price_usd,source FROM inventory_lots '
        'WHERE snapshot_id=? ORDER BY expiry_date,lot_key',(snapshot_id,))]


def write(connection, snapshot_id, lots):
    connection.execute('INSERT OR IGNORE INTO lot_snapshots VALUES (?)',(snapshot_id,))
    connection.execute('DELETE FROM inventory_lots WHERE snapshot_id=?',(snapshot_id,))
    for lot in lots:
        connection.execute('INSERT INTO inventory_lots VALUES (?,?,?,?,?,?,?)',
            (snapshot_id,lot['lot_key'],lot['batch_id'],lot['expiry_date'],lot['units'],lot['cost_price_usd'],lot['source']))


def allocate(lots, day, sales, waste):
    """Sell only unexpired units; then discard remaining units in expiry order."""
    remaining=[dict(lot) for lot in sorted(lots,key=lambda l:(l['expiry_date'],l['lot_key']))]
    movements=[]
    for kind,quantity in [('sales',sales),('waste',waste)]:
        for lot in remaining:
            if kind=='sales' and lot['expiry_date']<str(day):
                continue
            take=min(quantity,lot['units'])
            if take:
                lot['units']-=take
                quantity-=take
                movements.append({'lot_key':lot['lot_key'],'batch_id':lot['batch_id'],
                                  'kind':kind,'units':take,'expiry_date':lot['expiry_date']})
        if quantity:
            raise ValueError('Sales exceed sellable lot stock or waste exceeds remaining stock.')
    return remaining,movements


def ensure(connection, snapshot):
    """Backfill missing lot snapshots; preserve facts and label inference explicitly."""
    sid=snapshot['snapshot_id']
    if connection.execute('SELECT 1 FROM lot_snapshots WHERE snapshot_id=?',(sid,)).fetchone():
        lots=read(connection,sid)
        if sum(l['units'] for l in lots)!=snapshot['opening_inventory_units']:
            raise ValueError('Lot balance differs from snapshot; reconcile inventory before continuing.')
        return lots
    day=date.fromisoformat(snapshot['snapshot_date'])
    receipts=[(r[0],json.loads(r[1])) for r in connection.execute(
        "SELECT request_id,payload FROM receipts WHERE json_extract(payload,'$.store_id')=? "
        "AND json_extract(payload,'$.product_id')=? AND json_extract(payload,'$.received_date')=?",
        (snapshot['store_id'],snapshot['product_id'],str(day)))]
    base_units=snapshot['opening_inventory_units']-sum(r['quantity'] for _,r in receipts)
    if base_units<0:
        raise ValueError('Recorded receipts exceed snapshot stock; reconcile before migrating lots.')
    lots=[]
    prior=connection.execute('SELECT s.*,p.cost_price_usd FROM snapshots s JOIN products p USING(product_id) '
        'WHERE store_id=? AND product_id=? AND snapshot_date=?',
        (snapshot['store_id'],snapshot['product_id'],str(day-timedelta(days=1)))).fetchone()
    closure=connection.execute('SELECT payload FROM daily_closures WHERE store_id=? AND product_id=? AND date=?',
        (snapshot['store_id'],snapshot['product_id'],str(day-timedelta(days=1)))).fetchone()
    if prior and closure:
        previous=ensure(connection,dict(prior))
        close=json.loads(closure[0])
        try:
            candidates,_=allocate(previous,str(day-timedelta(days=1)),close['actual_sales_units'],close['units_wasted'])
            if sum(l['units'] for l in candidates)==base_units:
                lots=candidates
        except ValueError:
            pass  # Legacy data cannot substantiate a per-lot allocation.
    if not lots and base_units:
        lots=[{'lot_key':f'legacy:{sid}','batch_id':f'LEGACY-{sid}',
               'expiry_date':str(day+timedelta(days=snapshot['days_to_expiry'])),
               'units':base_units,'cost_price_usd':snapshot['cost_price_usd'],
               'source':'LEGACY_ESTIMATED_OPENING'}]
    for key,r in receipts:
        lots.append({'lot_key':'receipt:'+key,'batch_id':r['batch_id'],'expiry_date':r['expiry_date'],
                     'units':r['quantity'],'cost_price_usd':r['cost_price_usd'],'source':'RECORDED_RECEIPT'})
    write(connection,sid,lots)
    connection.execute('UPDATE snapshots SET revision=revision+1 WHERE snapshot_id=?',(sid,))
    return lots
