// Prove the downloaded bytes are the real .deb: a deb is an ar archive, so it
// must start with "!<arch>". Print the latin1 head, plus the release asset list.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function fetch(url) { return NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url)); }
function head(data, n) {
  return String(NSString.alloc().initWithData_encoding_(data, 5)).substring(0, n);
}

var asset = "https://github.com/yangzhou521/AxsTweakKit/releases/download/notesreadonly-v1.0.8/com.unknown.notesreadonly_1.0.8_iphoneos-arm64e.deb";
var data = fetch(asset);
print("asset len=" + (data ? data.length() : "nil"));
if (data) { print("asset head: " + head(data, 120).replace(/\n/g, "\\n")); }

var frag = fetch("https://github.com/yangzhou521/AxsTweakKit/releases/expanded_assets/notesreadonly-v1.0.8");
if (!frag) { print("expanded_assets -> NO DATA"); } else {
  var html = head(frag, 4000);
  var re = /href="([^"]*download[^"]*)"/g;
  var m, n = 0;
  while ((m = re.exec(html)) !== null && n < 5) { n++; print("asset link: " + m[1]); }
  if (n === 0) { print("expanded_assets: no download links (len=" + frag.length() + ")"); }
}
