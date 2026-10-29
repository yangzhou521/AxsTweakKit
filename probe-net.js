// Diagnose why the Actions API probe came back empty: is there a body at all?
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function probe(url) {
  var u = NSURL.URLWithString_(url);
  if (!u) { print(url + " -> bad URL"); return; }
  var data = NSData.dataWithContentsOfURL_(u);
  if (!data) { print(url + " -> NO DATA"); return; }
  var str = NSString.alloc().initWithData_encoding_(data, 4);
  print(url + " -> len=" + data.length() + " body: " + String(str).substring(0, 300));
}

probe("https://api.github.com/rate_limit");
probe("https://api.github.com/repos/yangzhou521/AxsTweakKit/actions/runs?per_page=3");
