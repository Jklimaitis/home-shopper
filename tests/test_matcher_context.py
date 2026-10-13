"""Real PostgreSQL regression proofs for matching context; synthetic data only."""
import importlib.util
import json
import os
import unittest
import uuid
from decimal import Decimal
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('matching_ingest_under_test', ROOT / 'scripts/ingest_receipt.py')
assert spec is not None and spec.loader is not None
ingest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ingest)
from services.matcher import match_staging_line


class MatcherContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dsn = os.environ.get('HS_INGEST_TEST_DSN')
        if not cls.dsn:
            raise unittest.SkipTest('Disposable HS_INGEST_TEST_DSN required')
        cls.conn = psycopg2.connect(cls.dsn)
        with cls.conn.cursor() as cur:
            cur.execute('SELECT current_database()')
            row = cur.fetchone()
            assert row is not None
            if not row[0].startswith('hs_ingest_test_'):
                cls.conn.close()
                raise RuntimeError('Refusing writes outside disposable database')
        cls.conn.rollback()

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def setUp(self):
        self.user, self.sa, self.sb, self.pa, self.pb, self.pra, self.prb, self.prc = [str(uuid.uuid4()) for _ in range(8)]
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute('INSERT INTO users(id,name,email) VALUES(%s,%s,%s)',
                            (self.user, 'Matcher test', self.user + '@example.invalid'))
                cur.execute('INSERT INTO stores(id,name,cnpj) VALUES(%s,%s,%s),(%s,%s,%s)',
                            (self.sa, 'TEST STORE A', '00000000000000', self.sb, 'TEST STORE B', '11111111111111'))
                cur.execute('INSERT INTO products(id,name,base_unit) VALUES(%s,%s,%s),(%s,%s,%s)',
                            (self.pa, 'MATCH PRODUCT A ' + self.pa, 'UN', self.pb, 'MATCH PRODUCT B ' + self.pb, 'G'))
                cur.execute('INSERT INTO presentations(id,product_id,factor_base,sale_unit_recognized) VALUES(%s,%s,%s,%s),(%s,%s,%s,%s),(%s,%s,%s,%s)',
                            (self.pra,self.pa,Decimal('1'),'UN',self.prb,self.pb,Decimal('1000'),'KG',self.prc,self.pb,Decimal('500'),'UN'))
                cur.execute('INSERT INTO presentation_identifiers(presentation_id,gtin,reviewed) VALUES(%s,%s,TRUE)',
                            (self.pra, '7891000412855'))

    def tearDown(self):
        self.conn.rollback()
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute('DELETE FROM users WHERE id=%s', (self.user,))
                cur.execute('DELETE FROM products WHERE id IN (%s,%s)', (self.pa,self.pb))
                cur.execute('DELETE FROM stores WHERE id IN (%s,%s)', (self.sa,self.sb))

    def add_source(self, presentation, store, unit='UN', reviewed=True, description='CONTEXT ITEM'):
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute('INSERT INTO presentation_sources(presentation_id,store_id,sale_unit,description_raw,description_search,reviewed) VALUES(%s,%s,%s,%s,%s,%s)',
                            (presentation,store,unit,description,description.lower(),reviewed))

    def ingest_item(self, *, store='A', description='UNKNOWN SYNTHETIC ITEM', unit='UN', code=None, gtin=None):
        payload = {'header': {'store_cnpj':'00000000000000' if store=='A' else '11111111111111', 'total_gross':'10','amount_paid':'10'},
                   'items':[{'description_raw':description,'sale_unit':unit,'quantity':'1','unit_price':'10','line_total':'10','store_code':code}]}
        if gtin is not None:
            payload['items'][0]['gtin'] = gtin
        note = ingest.parse_note(payload)
        with self.conn:
            rid = ingest.insert_staging_receipt(self.conn,note,self.user,'IMPORT')
            ingest.insert_staging_lines(self.conn,rid,note['items'])
        with self.conn.cursor() as cur:
            cur.execute('SELECT product_id,presentation_id,match_source,review_state,reviewed,store_code,match_note FROM staging_lines WHERE receipt_id=%s',(str(rid),))
            row = cur.fetchone()
            assert row is not None
            return row

    def test_internal_code_matching_gtin_is_not_treated_as_barcode(self):
        row = self.ingest_item(code='7891000412855')
        self.assertEqual(row[:3], (None,None,'NONE'))
        self.assertEqual(row[3:6], ('PENDING',False,'7891000412855'))


    def test_description_is_scoped_to_the_receipt_store(self):
        self.add_source(self.pra,self.sa)
        self.add_source(self.prc,self.sb)
        row = self.ingest_item(store='B',description='CONTEXT ITEM')
        self.assertEqual(row[:3],(self.pb,self.prc,'DESCRIPTION'))
        self.assertEqual(row[3:5],('PENDING',False))


    def test_conflicting_global_and_store_candidates_remain_unselected(self):
        self.add_source(self.pra,self.sa)
        self.add_source(self.prc,None)
        row = self.ingest_item(description='CONTEXT ITEM')
        self.assertEqual(row[:3],(None,None,'NONE'))
        note = json.loads(row[6])
        self.assertEqual(note['reason'],'ambiguous_description')
        self.assertEqual({c['presentation_id'] for c in note['candidates']},{self.pra,self.prc})
        self.assertEqual(row[3:5],('PENDING',False))


if __name__ == '__main__':
    unittest.main()
