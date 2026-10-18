import subprocess,tempfile,threading,unittest,sys
from pathlib import Path
from http.server import ThreadingHTTPServer
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'nas-sync-server'))
import server
from channel_store import ChannelStore
from market_data import MarketArchive
from market_runtime import MarketRuntime
class WorkerHTTPIntegration(unittest.TestCase):
 def test_actual_http_worker_restart_cannot_duplicate_fills_or_modify_real_assets(self):
  with tempfile.TemporaryDirectory()as temp:
   root=Path(temp);old=server.SYNC_TOKEN;server.SYNC_TOKEN='integration-test-only'
   http=ThreadingHTTPServer(('127.0.0.1',0),server.Handler)
   http.channel_store=ChannelStore(root/'channels-v2.sqlite3')
   http.market_runtime=MarketRuntime(http.channel_store,MarketArchive(root/'market-v2.sqlite3'))
   thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
   try:
    result=subprocess.run(['node',str(ROOT/'tests'/'worker-http-probe.cjs'),'http://127.0.0.1:'+str(http.server_port)],capture_output=True,text=True,encoding='utf8',timeout=30)
    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
    self.assertFalse((root/'sync.sqlite3').exists())
   finally:http.shutdown();http.server_close();thread.join();server.SYNC_TOKEN=old
