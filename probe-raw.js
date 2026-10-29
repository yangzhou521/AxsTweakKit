// Compare the pushed scripts/build-notesreadonly.sh at the failing commit (c74b783)
// and at master with the local working copy: which line matches substrate?
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function raw(ref) {
  var u = "https://raw.githubusercontent.com/yangzhou521/AxsTweakKit/" + ref + "/scripts/build-notesreadonly.sh";
  var d = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(u));
  if (!d) { return null; }
  return String(NSString.alloc().initWithData_encoding_(d, 4));
}

["c74b783", "087f112", "master"].forEach(function (ref) {
  var s = raw(ref);
  if (!s) { print(ref + ": NO DATA"); return; }
  print("=== " + ref + " (" + s.length + " chars) ===");
  s.split("\n").forEach(function (l, i) {
    if (l.indexOf("substrate") >= 0 && l.indexOf("awk") >= 0) {
      print("  line " + (i + 1) + ": " + l.trim());
    }
  });
});
