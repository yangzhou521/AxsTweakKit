// Is api.github.com answering at all, and what does the rate limit say?
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');
function fetch(u) {
  var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(u));
  if (!data) { return "nil"; }
  return String(NSString.alloc().initWithData_encoding_(data, 4));
}
var a = fetch("https://api.github.com/rate_limit");
print("rate_limit bytes=" + a.length + " :: " + a.substring(0, 300));
var b = fetch("https://api.github.com/repos/yangzhou521/AxsTweakKit/actions/runs?per_page=3");
print("runs bytes=" + b.length + " :: " + b.substring(0, 200));
