// For each sha that ran the NotesReadOnly workflow, print the check-runs and their
// annotations (annotations are public, the job log is not).
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function getJSON(url) {
  var d = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url));
  if (!d) { return null; }
  return JSON.parse(String(NSString.alloc().initWithData_encoding_(d, 4)));
}

var REPO = "yangzhou521/AxsTweakKit";
["087f112", "c74b783", "2f8c9b6"].forEach(function (sha) {
  print("=== sha " + sha + " ===");
  var cr = getJSON("https://api.github.com/repos/" + REPO + "/commits/" + sha + "/check-runs");
  if (!cr) { print("  NO DATA (check-runs)"); return; }
  ((cr.check_runs) || []).forEach(function (c) {
    print("  check " + c.name + " " + c.status + "/" + c.conclusion + " started " + c.started_at);
    var an = getJSON(c.url + "/annotations");
    ((an || [])).forEach(function (a) {
      if (a.message && a.message.indexOf("Node.js 20") >= 0) { return; }
      print("     [" + a.annotation_level + "][" + (a.title || "") + "] " + (a.message || ""));
    });
  });
});
