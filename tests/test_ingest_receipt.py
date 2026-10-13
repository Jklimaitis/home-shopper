"""Regression proofs for ingestion; integration requires a disposable test DB.

HS_INGEST_TEST_DSN must point to a database named hs_ingest_test_*.
Without it integration tests skip; unit tests never load a private .env.
"""
import importlib.util
import os
import sys
import unittest
import uuid
import io
import json
import tempfile
from unittest.mock import patch, MagicMock
from decimal import Decimal
from pathlib import Path

import psycopg2

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('ingest_under_test', ROOT/'scripts/ingest_receipt.py')
assert spec is not None and spec.loader is not None
ingest=importlib.util.module_from_spec(spec)
spec.loader.exec_module(ingest)


class IngestIdempotencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dsn=os.environ.get('HS_INGEST_TEST_DSN')
        if not cls.dsn:
            raise unittest.SkipTest('Integration requires disposable HS_INGEST_TEST_DSN')
        cls.conn=psycopg2.connect(cls.dsn)
        with cls.conn.cursor() as cur:
            cur.execute('SELECT current_database()')
            row=cur.fetchone(); assert row is not None
            db=row[0]
        if not db.startswith('hs_ingest_test_'):
            cls.conn.close()
            raise RuntimeError('Refusing integration writes outside hs_ingest_test_*')
        cls.conn.rollback()

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def setUp(self):
        self.ua,self.ub=str(uuid.uuid4()),str(uuid.uuid4())
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute('INSERT INTO users(id,name,email) VALUES(%s,%s,%s),(%s,%s,%s)',
                            (self.ua,'Test A',self.ua+'@example.invalid',self.ub,'Test B',self.ub+'@example.invalid'))
        self.note={'source_ref':'test-ref-'+uuid.uuid4().hex,'store_cnpj':None,'store_name':'TEST',
                   'total_gross':Decimal('10'),'amount_paid':Decimal('10'),'items':[]}

    def tearDown(self):
        self.conn.rollback()
        with self.conn:
            with self.conn.cursor() as cur:
                cur.execute('DELETE FROM users WHERE id IN (%s,%s)',(self.ua,self.ub))

    def test_other_user_can_import_same_ref(self):
        with self.conn:
            first=ingest.insert_staging_receipt(self.conn,self.note,self.ua,'IMPORT')
        try:
            with self.conn:
                second=ingest.insert_staging_receipt(self.conn,self.note,self.ub,'IMPORT')
        except ValueError:
            self.fail('The ingestion incorrectly rejected another owner')
        self.assertNotEqual(first,second)


    def test_concurrent_same_ref_is_one_insert_and_one_safe_duplicate(self):
        import threading
        barrier=threading.Barrier(2)
        outcomes=[]
        note=dict(self.note)
        owner=self.ua
        class CursorGate:
            def __init__(self,cur): self.cur=cur
            def __enter__(self): self.cur.__enter__(); return self
            def __exit__(self,*args): return self.cur.__exit__(*args)
            def execute(self,sql,args):
                if 'INSERT INTO staging_receipts' in sql:
                    barrier.wait(timeout=5)
                return self.cur.execute(sql,args)
            def fetchone(self): return self.cur.fetchone()
        class ConnectionGate:
            def __init__(self,conn): self.conn=conn
            def cursor(self): return CursorGate(self.conn.cursor())
        def worker():
            c=psycopg2.connect(self.dsn)
            try:
                with c:
                    with c.cursor() as cur: cur.execute("SET LOCAL lock_timeout='3s'")
                    ingest.insert_staging_receipt(ConnectionGate(c),note,owner,'IMPORT')
                outcomes.append('inserted')
            except ValueError as e:
                outcomes.append('safe_duplicate' if note['source_ref'] not in str(e) else 'leaked_reference')
            except Exception as e:
                outcomes.append(type(e).__name__)
            finally:
                c.close()
        threads=[threading.Thread(target=worker) for _ in range(2)]
        for t in threads: t.start()
        for t in threads: t.join(timeout=10)
        self.assertFalse(any(t.is_alive() for t in threads),'Concurrency probe exceeded wait')
        self.assertCountEqual(outcomes,['inserted','safe_duplicate'])
        with self.conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM staging_receipts WHERE user_id=%s AND source_ref=%s',
                        (owner,note['source_ref']))
            row=cur.fetchone(); assert row is not None
            self.assertEqual(row[0],1)


    def test_other_source_can_import_same_ref(self):
        with self.conn:
            first=ingest.insert_staging_receipt(self.conn,self.note,self.ua,'IMPORT')
            second=ingest.insert_staging_receipt(self.conn,self.note,self.ua,'OCR')
        self.assertNotEqual(first,second)

    def test_normalized_duplicate_has_no_uuid_or_reference_in_message(self):
        with self.conn:
            first=ingest.insert_staging_receipt(self.conn,{**self.note,'source_ref':self.note['source_ref'].upper()},self.ua,'IMPORT')
        with self.assertRaises(ValueError) as duplicate:
            with self.conn: ingest.insert_staging_receipt(self.conn,self.note,self.ua,'IMPORT')
        self.assertNotIn(str(first),str(duplicate.exception))
        self.assertNotIn(self.note['source_ref'],str(duplicate.exception))
        with self.conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM staging_receipts WHERE user_id=%s',(self.ua,))
            row=cur.fetchone(); assert row is not None
            self.assertEqual(row[0],1)

    def test_manual_receipts_without_ref_do_not_collide(self):
        ids=[]
        with self.conn:
            for ref in (None,None,'',''):
                ids.append(ingest.insert_staging_receipt(self.conn,{**self.note,'source_ref':ref},self.ua,'MANUAL'))
        self.assertEqual(len(set(ids)),4)

    def test_failed_matcher_rolls_back_header_and_prior_lines(self):
        item={'line_no':1,'description_raw':'TEST NO MATCH','store_code':None,'sale_unit':'UN',
              'quantity':Decimal('1'),'unit_price':Decimal('10'),'line_total':Decimal('10')}
        rid=None
        try:
            with self.conn:
                rid=ingest.insert_staging_receipt(self.conn,self.note,self.ua,'IMPORT')
                ingest.insert_staging_lines(self.conn,rid,[item])
                with patch.object(ingest,'match_staging_line',side_effect=RuntimeError('synthetic matcher failure')):
                    ingest.insert_staging_lines(self.conn,rid,[{**item,'line_no':2}])
        except RuntimeError as error:
            self.assertEqual(str(error),'synthetic matcher failure')
        else:
            self.fail('The synthetic matcher failure was not propagated')
        self.assertIsNotNone(rid)
        with self.conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM staging_receipts WHERE user_id=%s',(self.ua,))
            row=cur.fetchone(); assert row is not None
            self.assertEqual(row[0],0)
            cur.execute('SELECT count(*) FROM staging_lines WHERE receipt_id=%s',(str(rid),))
            row=cur.fetchone(); assert row is not None
            self.assertEqual(row[0],0)

    def test_duplicate_cli_does_not_append_lines(self):
        with tempfile.TemporaryDirectory() as folder:
            payload=Path(folder)/'synthetic.json'
            payload.write_text(json.dumps({'header':{'access_key':'0'*44,'total_gross':'10','amount_paid':'10'},
                'items':[{'description_raw':'SYNTHETIC TEST','sale_unit':'UN','quantity':'1','unit_price':'10','line_total':'10'}]}))
            with patch.object(ingest,'load_dotenv'), \
                 patch.object(ingest,'connect_database',side_effect=lambda:psycopg2.connect(self.dsn)), \
                 patch.object(sys,'argv',['ingest_receipt.py',str(payload),'--user-id',self.ua,'--source','IMPORT']), \
                 patch('sys.stdout',new_callable=io.StringIO):
                ingest.main()
                with self.assertRaises(SystemExit) as stopped: ingest.main()
                self.assertEqual(stopped.exception.code,1)
            with self.conn.cursor() as cur:
                cur.execute('SELECT count(*) FROM staging_receipts WHERE user_id=%s',(self.ua,))
                row=cur.fetchone(); assert row is not None
                self.assertEqual(row[0],1)
                cur.execute('SELECT count(*) FROM staging_lines sl JOIN staging_receipts sr ON sr.id=sl.receipt_id WHERE sr.user_id=%s',(self.ua,))
                row=cur.fetchone(); assert row is not None
                self.assertEqual(row[0],1)


    def test_db_keyword_connection_handles_password_special_characters(self):
        from psycopg2.extensions import parse_dsn
        assert self.dsn is not None
        settings=parse_dsn(self.dsn)
        env={'DB_HOST':settings['host'],'DB_PORT':settings['port'],
             'DB_NAME':settings['dbname'],'DB_USER':settings['user'],
             'DB_PASSWORD':"synthetic words host=alternate.invalid ' \\"}
        with patch.dict(os.environ,env,clear=True):
            c=ingest.connect_database()
        try:
            with c.cursor() as cur:
                cur.execute('SELECT current_database()')
                row=cur.fetchone(); assert row is not None
                self.assertEqual(row[0],settings['dbname'])
        finally:
            c.close()


class IngestConnectionTests(unittest.TestCase):
    def test_db_settings_are_passed_as_keywords_without_dsn_interpolation(self):
        env={'DB_HOST':'127.0.0.1','DB_PORT':'55432','DB_NAME':'hs_ingest_test_unit',
             'DB_USER':'test_owner','DB_PASSWORD':"synthetic words host=alternate.invalid ' \\"}
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ,env,clear=True):
            payload=Path(folder)/'test.json'
            payload.write_text(json.dumps({'header':{'total_gross':'1','amount_paid':'1'},'items':[]}))
            local_spec=importlib.util.spec_from_file_location('connection_test_ingest',ROOT/'scripts/ingest_receipt.py')
            assert local_spec is not None and local_spec.loader is not None
            module=importlib.util.module_from_spec(local_spec)
            local_spec.loader.exec_module(module)
            with patch.object(module,'load_dotenv'), \
                 patch.object(module.psycopg2,'connect',side_effect=RuntimeError('test stop')) as connect, \
                 patch.object(sys,'argv',['ingest_receipt.py',str(payload)]), \
                 patch('sys.stdout',new_callable=io.StringIO):
                with self.assertRaises(SystemExit): module.main()
            args,kwargs=connect.call_args
            self.assertEqual(args,(),'DB settings must not form a positional DSN')
            self.assertEqual(kwargs,{'host':env['DB_HOST'],'port':env['DB_PORT'],
                                     'dbname':env['DB_NAME'],'user':env['DB_USER'],
                                     'password':env['DB_PASSWORD']})


    def test_cli_errors_do_not_echo_exception_details(self):
        marker='private-synthetic-marker'
        errors=[psycopg2.OperationalError(marker),ValueError(marker),RuntimeError(marker)]
        with tempfile.TemporaryDirectory() as folder:
            payload=Path(folder)/'test.json'
            payload.write_text(json.dumps({'header':{'total_gross':'1','amount_paid':'1'},'items':[]}))
            for error in errors:
                with self.subTest(error_type=type(error).__name__), \
                     patch.object(ingest,'load_dotenv'), \
                     patch.object(ingest.psycopg2,'connect',side_effect=error), \
                     patch.object(sys,'argv',['ingest_receipt.py',str(payload)]), \
                     patch('sys.stdout',new_callable=io.StringIO) as stdout, \
                     patch('sys.stderr',new_callable=io.StringIO) as stderr:
                    with self.assertRaises(SystemExit) as stopped: ingest.main()
                    self.assertEqual(stopped.exception.code,1)
                    self.assertNotIn(marker,stdout.getvalue()+stderr.getvalue())


    def test_import_does_not_read_private_env(self):
        local_spec=importlib.util.spec_from_file_location('env_import_test',ROOT/'scripts/ingest_receipt.py')
        assert local_spec is not None and local_spec.loader is not None
        module=importlib.util.module_from_spec(local_spec)
        original_is_file=Path.is_file
        def is_file(path): return True if path.name=='.env' else original_is_file(path)
        with patch.object(Path,'is_file',is_file), \
             patch.object(Path,'read_text',side_effect=AssertionError('private env read on import')):
            try:
                local_spec.loader.exec_module(module)
            except AssertionError:
                self.fail('Importing ingestion must not read a private configuration file')


    def test_input_and_config_failures_are_sanitized(self):
        from contextlib import ExitStack
        marker='private-synthetic-marker'
        scenarios=('read','parse','env','missing')
        with tempfile.TemporaryDirectory() as folder:
            payload=Path(folder)/'test.json'
            for scenario in scenarios:
                payload.write_text(json.dumps({'header':{'total_gross':marker if scenario=='parse' else '1'},'items':[]}))
                path=Path(folder)/(marker+'.json') if scenario=='missing' else payload
                with self.subTest(scenario=scenario), ExitStack() as stack:
                    stack.enter_context(patch.object(sys,'argv',['ingest_receipt.py',str(path)]))
                    stdout=stack.enter_context(patch('sys.stdout',new_callable=io.StringIO))
                    stderr=stack.enter_context(patch('sys.stderr',new_callable=io.StringIO))
                    connect=stack.enter_context(patch.object(ingest.psycopg2,'connect'))
                    if scenario=='read': stack.enter_context(patch('builtins.open',side_effect=PermissionError(marker)))
                    if scenario=='env': stack.enter_context(patch.object(ingest,'load_dotenv',side_effect=OSError(marker)))
                    else: stack.enter_context(patch.object(ingest,'load_dotenv'))
                    try:
                        ingest.main()
                    except SystemExit as e:
                        self.assertEqual(e.code,1)
                    except Exception:
                        self.fail('CLI input/config failure escaped the safe error boundary')
                    else:
                        self.fail('Invalid input unexpectedly succeeded')
                    self.assertNotIn(marker,stdout.getvalue()+stderr.getvalue())
                    connect.assert_not_called()


    def test_empty_database_url_fails_before_connect(self):
        with patch.dict(os.environ,{'DATABASE_URL':'   '},clear=True), \
             patch.object(ingest.psycopg2,'connect') as connect:
            with self.assertRaises(ValueError): ingest.connect_database()
            connect.assert_not_called()

    def test_database_url_keeps_precedence(self):
        url='postgresql://test_owner@127.0.0.1/hs_ingest_test_unit'
        with patch.dict(os.environ,{'DATABASE_URL':url,'DB_HOST':'ignored.invalid'},clear=True), \
             patch.object(ingest.psycopg2,'connect') as connect:
            ingest.connect_database()
            connect.assert_called_once_with(url)


    def test_cleanup_failure_does_not_escape_safe_error_boundary(self):
        marker='private-synthetic-marker'
        for failure in ('rollback','close'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder:
                payload=Path(folder)/'test.json'
                payload.write_text(json.dumps({'header':{'total_gross':'1','amount_paid':'1'},'items':[]}))
                conn=MagicMock(); conn.closed=False
                conn.__enter__.return_value=conn
                # psycopg2's context manager owns rollback. Simulate failure
                # at that boundary, not on an unused explicit rollback mock.
                if failure=='rollback': conn.__exit__.side_effect=psycopg2.OperationalError(marker)
                else: conn.close.side_effect=psycopg2.OperationalError(marker)
                with patch.object(ingest,'load_dotenv'), \
                     patch.object(ingest,'connect_database',return_value=conn), \
                     patch.object(ingest,'insert_staging_receipt',side_effect=psycopg2.OperationalError(marker)), \
                     patch.object(sys,'argv',['ingest_receipt.py',str(payload)]), \
                     patch('sys.stdout',new_callable=io.StringIO) as stdout, \
                     patch('sys.stderr',new_callable=io.StringIO) as stderr:
                    try:
                        ingest.main()
                    except SystemExit as e:
                        self.assertEqual(e.code,1)
                    except Exception:
                        self.fail('Cleanup failure escaped the safe error boundary')
                    else:
                        self.fail('Database failure unexpectedly succeeded')
                    self.assertNotIn(marker,stdout.getvalue()+stderr.getvalue())
                    conn.__exit__.assert_called_once()
                    conn.close.assert_called_once()


    def test_runtime_dotenv_honors_quotes_and_existing_environment(self):
        import shutil
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ,{'DB_HOST':'exported-host'},clear=True):
            project=Path(folder)/'project'
            (project/'scripts').mkdir(parents=True)
            shutil.copyfile(ROOT/'scripts/ingest_receipt.py',project/'scripts/ingest_receipt.py')
            (project/'.env').write_text("DB_HOST=ignored-host\nDB_PASSWORD='synthetic two words'\nDB_USER=test_owner\nDB_NAME=hs_ingest_test_unit\n")
            payload=project/'test.json'
            payload.write_text(json.dumps({'header':{'total_gross':'1'},'items':[]}))
            local_spec=importlib.util.spec_from_file_location('relocated_ingest_test',project/'scripts/ingest_receipt.py')
            assert local_spec is not None and local_spec.loader is not None
            module=importlib.util.module_from_spec(local_spec); local_spec.loader.exec_module(module)
            with patch.object(module.psycopg2,'connect',side_effect=RuntimeError('test stop')) as connect, \
                 patch.object(sys,'argv',['ingest_receipt.py',str(payload)]), \
                 patch('sys.stdout',new_callable=io.StringIO):
                with self.assertRaises(SystemExit): module.main()
            args,kwargs=connect.call_args
            self.assertEqual(args,())
            self.assertEqual(kwargs['password'],'synthetic two words')
            self.assertEqual(kwargs['host'],'exported-host')
            self.assertEqual(kwargs['dbname'],'hs_ingest_test_unit')


if __name__=='__main__':
    unittest.main()
