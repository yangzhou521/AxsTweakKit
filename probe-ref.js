// Where master points now, and the newest runs — to explain why run #3 was cancelled.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function getJSON(url) {
  var d = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url));
  if (!d) { return null; }
  return JSON.parse(String(NSString.alloc().initWithData_encoding_(d, 4)));
}

var REPO = "yangzhou521/AxsTweakKit";
var ref = getJSON("https://api.github.com/repos/" + REPO + "/git/ref/heads/master");
print("master = " + (ref && ref.object ? ref.object.sha : "NO DATA"));

var runs = getJSON("https://api.github.com/repos/" + REPO + "/actions/runs?per_page=6");
if (!runs) { print("NO DATA (runs)"); } else {
  (runs.workflow_runs || []).forEach(function (r) {
    print("#" + r.run_number + " " + r.name + " " + r.status + "/" + r.conclusion +
          " " + r.event + " sha=" + r.head_sha.substring(0, 7) + " created=" + r.created_at +
          " updated=" + r.updated_at);
  });
}
