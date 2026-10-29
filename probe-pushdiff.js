// What exactly will be pushed: diff the local build-notesreadonly.sh against the
// pushed one at the failing commit, and show the local repo's recent reflog lines.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');
var FM = ObjC.use('NSFileManager');

var PROJ = "/private/var/mobile/Containers/Shared/AppGroup/.jbroot-E0BF8A83B883CBA6/var/mobile/Documents/wiki.qaq.apelin/Projects/AxsTweakKitGitHub";

function readLocal(p) {
  var s = NSString.stringWithContentsOfFile_encoding_error_(PROJ + "/" + p, 4, null);
  return s ? String(s) : null;
}
function raw(ref, p) {
  var u = "https://raw.githubusercontent.com/yangzhou521/AxsTweakKit/" + ref + "/" + p;
  var d = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(u));
  if (!d) { return null; }
  return String(NSString.alloc().initWithData_encoding_(d, 4));
}

function diff(local, remote, label) {
  if (local == null) { print(label + ": local unreadable"); return; }
  if (remote == null) { print(label + ": remote unreadable"); return; }
  var L = local.split("\n"), R = remote.split("\n");
  print("=== " + label + " local " + L.length + " lines / remote " + R.length + " lines ===");
  var rs = {}, ls = {};
  R.forEach(function (l) { rs[l] = (rs[l] || 0) + 1; });
  L.forEach(function (l) { ls[l] = (ls[l] || 0) + 1; });
  L.forEach(function (l, i) {
    if (!rs[l]) { print("  +" + (i + 1) + ": " + l); }
  });
  R.forEach(function (l, i) {
    if (!ls[l]) { print("  -" + (i + 1) + ": " + l); }
  });
}

diff(readLocal("scripts/build-notesreadonly.sh"), raw("c74b783", "scripts/build-notesreadonly.sh"), "build-notesreadonly.sh vs c74b783");
diff(readLocal(".github/workflows/notesreadonly.yml"), raw("c74b783", ".github/workflows/notesreadonly.yml"), "notesreadonly.yml vs c74b783");
diff(readLocal("NotesReadOnly/Sources/NotesReadOnly.m"), raw("c74b783", "NotesReadOnly/Sources/NotesReadOnly.m"), "NotesReadOnly.m vs c74b783");

var reflog = readLocal(".git/logs/HEAD");
print("=== reflog tail ===");
if (reflog) {
  var lines = reflog.split("\n").filter(function (l) { return l.length > 0; });
  lines.slice(Math.max(0, lines.length - 6)).forEach(function (l) {
    var parts = l.split("\t");
    print("  " + l.substring(0, 9) + " " + (parts[1] || ""));
  });
} else {
  print("  unreadable");
}
