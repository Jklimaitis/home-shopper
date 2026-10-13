"""Regression tests for literal ingestion values; only synthetic inputs."""
import importlib.util
import unittest
from pathlib import Path
from decimal import Decimal

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('ingest_values_under_test',ROOT/'scripts/ingest_receipt.py')
assert spec is not None and spec.loader is not None
ingest=importlib.util.module_from_spec(spec); spec.loader.exec_module(ingest)


def valid_note():
    return {'header':{'total_gross':'10','amount_paid':'10'},
            'items':[{'description_raw':'SYNTHETIC ITEM','sale_unit':'UN','quantity':'1','unit_price':'10','line_total':'10'}]}


class IngestValueParserTests(unittest.TestCase):
    def test_explicit_zero_wins_over_legacy_alias(self):
        payload={'header':{'total_gross':0,'total':99,'amount_paid':0,'total_liquido':99},
                 'items':[{'description_raw':'ZERO TEST','sale_unit':'UN','quantity':0,'quantidade':2,
                           'unit_price':0,'valor_unitario':5,'line_total':0,'valor_total':3}]}
        note=ingest.parse_note(payload)
        values=[note['total_gross'],note['amount_paid']]+[note['items'][0][key] for key in ('quantity','unit_price','line_total')]
        self.assertEqual(values,[Decimal('0')]*5)


    def test_unknown_totals_remain_none_without_inference(self):
        for header in ({},{'total_gross':'10'},{'total_gross':'10','discount':'2'},
                       {'total_gross':None,'total':99,'amount_paid':None,'total_liquido':99}):
            with self.subTest(header=header):
                payload=valid_note(); payload['header']=header
                note=ingest.parse_note(payload)
                self.assertIsNone(note['amount_paid'])
                if 'total_gross' not in header or header['total_gross'] is None:
                    self.assertIsNone(note['total_gross'])


    def test_missing_required_line_numbers_are_rejected(self):
        for field in ('quantity','unit_price','line_total'):
            for missing in ('absent',None,''):
                with self.subTest(field=field,missing=missing):
                    payload=valid_note()
                    if missing=='absent': del payload['items'][0][field]
                    else: payload['items'][0][field]=missing
                    with self.assertRaises(ValueError): ingest.parse_note(payload)


    def test_invalid_financial_numbers_are_rejected_safely(self):
        invalid=(True,False,'NaN','sNaN','Infinity','-Infinity','-1','not-a-number',[],{})
        for field in ('total_gross','amount_paid','quantity','unit_price','line_total'):
            for value in invalid:
                with self.subTest(field=field,value_type=type(value).__name__):
                    payload=valid_note()
                    target=payload['header'] if field in ('total_gross','amount_paid') else payload['items'][0]
                    target[field]=value
                    try: ingest.parse_note(payload)
                    except ValueError: pass
                    except Exception: self.fail('Invalid numeric input did not become a safe validation error')
                    else: self.fail('Invalid numeric input was accepted')


    def test_source_reference_is_preserved_literally(self):
        references=(' upload-demo-001 ','https://example.invalid/note/123?token=AbC-45',
                    '-'.join('0'*n for n in (2,4,14,2,3,9,9,1)))
        for field in ('source_ref','access_key'):
            for ref in references:
                with self.subTest(field=field):
                    payload=valid_note(); payload['header'][field]=ref
                    self.assertEqual(ingest.parse_note(payload)['source_ref'],ref)


    def test_sale_unit_is_literal_and_missing_is_rejected(self):
        for label in ('Kg',' c/N ','CX10','FRASCO'):
            payload=valid_note(); payload['items'][0]['sale_unit']=label
            self.assertEqual(ingest.parse_note(payload)['items'][0]['sale_unit'],label)
        for value in (None,'','   ',7,False):
            with self.subTest(unit_type=type(value).__name__):
                payload=valid_note(); payload['items'][0]['sale_unit']=value
                try: ingest.parse_note(payload)
                except ValueError: pass
                except Exception: self.fail('Unit error escaped validation')
                else: self.fail('Missing or invalid unit received a default')
        payload=valid_note(); del payload['items'][0]['sale_unit']
        with self.assertRaises(ValueError): ingest.parse_note(payload)


    def test_json_financial_numbers_reach_parser_as_exact_decimals(self):
        import tempfile,sys,io
        from unittest.mock import patch
        literal='0.123456789123456789'
        text='{"header":{"total_gross":'+literal+'},"items":[]}'
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'synthetic.json'; path.write_text(text)
            with patch.object(ingest,'load_dotenv'), \
                 patch.object(ingest,'parse_note',wraps=ingest.parse_note) as parse, \
                 patch.object(ingest,'connect_database',side_effect=RuntimeError('synthetic stop')), \
                 patch.object(sys,'argv',['ingest_receipt.py',str(path)]), \
                 patch('sys.stdout',new_callable=io.StringIO):
                with self.assertRaises(SystemExit): ingest.main()
            value=parse.call_args.args[0]['header']['total_gross']
            self.assertIsInstance(value,Decimal)
            self.assertEqual(value,Decimal(literal))


    def test_canonical_header_and_item_containers_win_even_when_empty(self):
        payload={'header':{},'nota':{'valor_total':'99','valor_pago':'99'},'items':[],
                 'itens':[{'descricao':'LEGACY','unidade':'UN','quantidade':'1','valor_unitario':'99','valor_total':'99'}]}
        note=ingest.parse_note(payload)
        self.assertIsNone(note['total_gross'])
        self.assertIsNone(note['amount_paid'])
        self.assertEqual(note['items'],[])


    def test_discount_defaults_and_explicit_zero_follow_schema_contract(self):
        note=ingest.parse_note(valid_note())
        self.assertEqual(note['discount_total'],Decimal('0'))
        self.assertEqual(note['items'][0]['discount_line'],Decimal('0'))
        payload=valid_note(); payload['header'].update(discount_total=0,discount=7)
        payload['items'][0].update(discount_line=0,discount=3)
        note=ingest.parse_note(payload)
        self.assertEqual(note['discount_total'],Decimal('0'))
        self.assertEqual(note['items'][0]['discount_line'],Decimal('0'))
        for field,place in (('discount_total','header'),('discount_line','line')):
            for invalid in (None,'',True,'NaN','-1'):
                payload=valid_note()
                target=payload['header'] if place=='header' else payload['items'][0]
                target[field]=invalid
                with self.subTest(field=field),self.assertRaises(ValueError): ingest.parse_note(payload)

    def test_portuguese_aliases_and_decimal_comma_remain_supported(self):
        payload={'nota':{'valor_total':'10,00','valor_pago':'9,00','desconto':'1,00'},
                 'itens':[{'descricao':' ITEM FICTICIO ','unidade':' Kg ','quantidade':'1,25','valor_unitario':'8,00','valor_total':'10,00','desconto_linha':'0,00'}]}
        note=ingest.parse_note(payload); item=note['items'][0]
        self.assertEqual((note['total_gross'],note['discount_total'],note['amount_paid']),(Decimal('10'),Decimal('1'),Decimal('9')))
        self.assertEqual(item['quantity']*item['unit_price'],item['line_total'])
        self.assertEqual(item['sale_unit'],' Kg ')
        self.assertEqual(item['description_raw'],' ITEM FICTICIO ')

    def test_invalid_structures_and_nontext_reference_fail_validation(self):
        for payload in ([],None,{'header':None},{'items':None},{'items':[None]}):
            with self.subTest(payload_type=type(payload).__name__),self.assertRaises(ValueError): ingest.parse_note(payload)
        for ref in (123,False,{}):
            payload=valid_note(); payload['header']['source_ref']=ref
            with self.assertRaises(ValueError): ingest.parse_note(payload)


    def test_declared_none_is_not_replaced_by_legacy_alias(self):
        line_aliases={'quantity':('quantidade','2'),'unit_price':('valor_unitario','3'),
                      'line_total':('valor_total','4'),'discount_line':('discount','1'),
                      'sale_unit':('unidade','UN')}
        for field,(alias,value) in line_aliases.items():
            payload=valid_note(); payload['items'][0].update({field:None,alias:value})
            with self.subTest(field=field),self.assertRaises(ValueError): ingest.parse_note(payload)
        payload=valid_note(); payload['header'].update(discount_total=None,discount='1')
        with self.assertRaises(ValueError): ingest.parse_note(payload)
        payload=valid_note(); payload['header'].update(source_ref=None,access_key='upload-legacy-001')
        self.assertIsNone(ingest.parse_note(payload)['source_ref'])


import os
import uuid
import psycopg2


class IngestValueStorageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dsn=os.environ.get('HS_INGEST_TEST_DSN')
        if not cls.dsn: raise unittest.SkipTest('Disposable HS_INGEST_TEST_DSN required')
        cls.conn=psycopg2.connect(cls.dsn)
        with cls.conn.cursor() as cur:
            cur.execute('SELECT current_database()'); row=cur.fetchone(); assert row is not None
            if not row[0].startswith('hs_ingest_test_'):
                cls.conn.close(); raise RuntimeError('Refusing writes outside disposable database')
        cls.conn.rollback()

    @classmethod
    def tearDownClass(cls): cls.conn.close()

    def setUp(self):
        self.user=str(uuid.uuid4())
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute('INSERT INTO users(id,name,email) VALUES(%s,%s,%s)',(self.user,'Value test',self.user+'@example.invalid'))

    def tearDown(self):
        self.conn.rollback()
        with self.conn:
            with self.conn.cursor() as cur: cur.execute('DELETE FROM users WHERE id=%s',(self.user,))

    def store(self,payload):
        note=ingest.parse_note(payload)
        with self.conn:
            rid=ingest.insert_staging_receipt(self.conn,note,self.user,'IMPORT')
            ingest.insert_staging_lines(self.conn,rid,note['items'])
        return rid

    def test_receipt_and_line_discounts_survive_storage(self):
        payload=valid_note(); payload['header'].update(discount='2',amount_paid='8')
        payload['items'][0].update(unit_price='11',discount_line='1')
        rid=self.store(payload)
        with self.conn.cursor() as cur:
            cur.execute('SELECT sr.total_gross,sr.discount_total,sr.amount_paid,sl.discount_line FROM staging_receipts sr JOIN staging_lines sl ON sl.receipt_id=sr.id WHERE sr.id=%s',(str(rid),))
            self.assertEqual(cur.fetchone(),(Decimal('10'),Decimal('2'),Decimal('8'),Decimal('1')))


    def test_cli_stores_unknown_totals_without_reporting_failure(self):
        import tempfile,json,sys,io
        from unittest.mock import patch
        payload=valid_note(); payload['header']={}
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'synthetic.json'; path.write_text(json.dumps(payload))
            with patch.object(ingest,'load_dotenv'), \
                 patch.object(ingest,'connect_database',side_effect=lambda:psycopg2.connect(self.dsn)), \
                 patch.object(sys,'argv',['ingest_receipt.py',str(path),'--user-id',self.user,'--source','IMPORT']), \
                 patch('sys.stdout',new_callable=io.StringIO) as stdout:
                try: ingest.main()
                except SystemExit: self.fail('A receipt with nullable totals was reported as failed')
                self.assertIn('não informado',stdout.getvalue())
                self.assertNotIn('[!]',stdout.getvalue())
        with self.conn.cursor() as cur:
            cur.execute('SELECT total_gross,amount_paid,divergence_cents,status FROM staging_receipts WHERE user_id=%s',(self.user,))
            self.assertEqual(cur.fetchone(),(None,None,None,'PENDING'))


    def test_zero_values_survive_storage_without_replacement(self):
        payload=valid_note(); payload['header'].update(total_gross=0,amount_paid=0,discount_total=0)
        payload['items'][0].update(quantity=0,unit_price=0,line_total=0,discount_line=0)
        rid=self.store(payload)
        with self.conn.cursor() as cur:
            cur.execute('SELECT sr.total_gross,sr.amount_paid,sr.discount_total,sl.quantity,sl.unit_price,sl.line_total,sl.discount_line FROM staging_receipts sr JOIN staging_lines sl ON sl.receipt_id=sr.id WHERE sr.id=%s',(str(rid),))
            self.assertEqual(cur.fetchone(),tuple(Decimal('0') for _ in range(7)))

    def test_raw_reference_unit_and_description_survive_storage(self):
        payload=valid_note(); ref=' https://example.invalid/note/001?token=AbC-45 '
        payload['header']['source_ref']=ref
        payload['items'][0].update(sale_unit=' Kg ',description_raw=' ITEM FICTICIO ')
        rid=self.store(payload)
        with self.conn.cursor() as cur:
            cur.execute('SELECT sr.source_ref,sl.sale_unit,sl.description_raw,sl.review_state,sl.reviewed FROM staging_receipts sr JOIN staging_lines sl ON sl.receipt_id=sr.id WHERE sr.id=%s',(str(rid),))
            self.assertEqual(cur.fetchone(),(ref,' Kg ',' ITEM FICTICIO ','PENDING',False))

    def test_distinct_refs_with_same_digits_do_not_collide(self):
        ids=[]
        for ref in ('upload-A-001','upload-B-001'):
            payload=valid_note(); payload['header']['source_ref']=ref
            ids.append(self.store(payload))
        self.assertNotEqual(ids[0],ids[1])
        with self.conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM staging_receipts WHERE user_id=%s',(self.user,))
            self.assertEqual(cur.fetchone(),(2,))

    def test_incomplete_second_line_is_rejected_before_database(self):
        import tempfile,json,sys,io
        from unittest.mock import patch
        payload=valid_note(); payload['items'].append({'description_raw':'SECOND LINE','sale_unit':'UN','quantity':'1','line_total':'10'})
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'synthetic.json'; path.write_text(json.dumps(payload))
            with patch.object(ingest,'load_dotenv'), \
                 patch.object(ingest,'connect_database') as connect, \
                 patch.object(sys,'argv',['ingest_receipt.py',str(path)]), \
                 patch('sys.stdout',new_callable=io.StringIO):
                with self.assertRaises(SystemExit) as stopped: ingest.main()
                self.assertEqual(stopped.exception.code,1)
                connect.assert_not_called()
        with self.conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM staging_receipts WHERE user_id=%s',(self.user,))
            self.assertEqual(cur.fetchone(),(0,))


    def test_cli_handles_each_nullable_total_independently(self):
        import tempfile,json,sys,io
        from unittest.mock import patch
        for missing in ('total_gross','amount_paid'):
            with self.subTest(missing=missing),tempfile.TemporaryDirectory() as folder:
                payload=valid_note(); del payload['header'][missing]
                ref='test-unknown-'+missing; payload['header']['source_ref']=ref
                path=Path(folder)/'synthetic.json'; path.write_text(json.dumps(payload))
                with patch.object(ingest,'load_dotenv'), \
                     patch.object(ingest,'connect_database',side_effect=lambda:psycopg2.connect(self.dsn)), \
                     patch.object(sys,'argv',['ingest_receipt.py',str(path),'--user-id',self.user,'--source','IMPORT']), \
                     patch('sys.stdout',new_callable=io.StringIO) as stdout:
                    ingest.main()
                    self.assertIn('não informado',stdout.getvalue())
                    self.assertNotIn('[!]',stdout.getvalue())
                with self.conn.cursor() as cur:
                    cur.execute('SELECT total_gross,amount_paid,divergence_cents,status FROM staging_receipts WHERE user_id=%s AND source_ref=%s',(self.user,ref))
                    expected=(None,Decimal('10'),None,'PENDING') if missing=='total_gross' else (Decimal('10'),None,0,'PENDING')
                    self.assertEqual(cur.fetchone(),expected)


if __name__=='__main__': unittest.main()
