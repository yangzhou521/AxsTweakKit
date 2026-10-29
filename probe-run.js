// Status of one Actions run plus its jobs: follow the NotesReadOnly build.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function getJSON(url) {
  var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url));
  if (!data) { return null; }
  return JSON.parse(String(NSString.alloc().initWithData_encoding_(data, 4)));
}

var RUN = "40847868915";
var r = getJSON("https://api.github.com/repos/yangzhou521/AxsTweakKit/actions/runs/" + RUN);
if (!r) {
  print("NO DATA (rate limited?)");
} else {
  print("run " + r.run_number + " id=" + r.id + " " + r.status + "/" + r.conclusion +
        " sha=" + r.head_sha.substring(0, 7));
  var jobs = getJSON("https://api.github.com/repos/yangzhou521/AxsTweakKit/actions/runs/" + RUN + "/jobs");
  ((jobs && jobs.jobs) || []).forEach(function (j) {
    print("job " + j.name + " id=" + j.id + " " + j.status + "/" + j.conclusion);
    (j.steps || []).forEach(function (s) {
      print("   step " + s.number + " " + s.name + " " + s.status + "/" + s.conclusion);
    });
  });
}
