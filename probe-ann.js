// Read the check-run annotations of the newest run: they are public even when the job log is not.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function getJSON(url) {
  var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url));
  if (!data) { return null; }
  return JSON.parse(String(NSString.alloc().initWithData_encoding_(data, 4)));
}

var REPO = "yangzhou521/AxsTweakKit";
var RUN = "40847868915";
var r = getJSON("https://api.github.com/repos/" + REPO + "/actions/runs/" + RUN);
if (!r) { print("NO DATA (run)"); } else {
  var sha = r.head_sha;
  print("sha=" + sha.substring(0, 7) + " " + r.status + "/" + r.conclusion);
  var cr = getJSON("https://api.github.com/repos/" + REPO + "/commits/" + sha + "/check-runs");
  if (!cr) { print("NO DATA (check-runs)"); } else {
    (cr.check_runs || []).forEach(function (c) {
      print("check " + c.name + " id=" + c.id + " " + c.status + "/" + c.conclusion);
      if (c.output && c.output.title) { print("   title: " + c.output.title); }
      if (c.output && c.output.summary) { print("   summary: " + c.output.summary); }
      var an = getJSON(c.url + "/annotations");
      ((an && an.length !== undefined) ? an : []).forEach(function (a) {
        print("   [" + a.annotation_level + "][" + (a.title || "") + "] " + (a.message || ""));
      });
    });
  }
}
