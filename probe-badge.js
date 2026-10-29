// GitHub API is rate limited (60/h, used up), so read the workflow badge and the
// Actions HTML page instead: github.com is not part of the api.github.com limit.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function fetchText(url) {
  var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url));
  if (!data) { return null; }
  return String(NSString.alloc().initWithData_encoding_(data, 4));
}

function badge(workflow) {
  var url = "https://github.com/yangzhou521/AxsTweakKit/actions/workflows/" + workflow + "/badge.svg";
  var svg = fetchText(url);
  if (!svg) { print(workflow + " badge -> NO DATA"); return; }
  var m = svg.match(/>([^<>]*(passing|failing|no status|unknown)[^<>]*)</i);
  var title = svg.match(/<title>([^<]*)<\/title>/);
  print(workflow + " badge -> " + (m ? m[1] : "?") + " | " + (title ? title[1] : ""));
}

badge("notesreadonly.yml");
badge("build.yml");

// The HTML page embeds each run's conclusion in JSON; print the newest few.
var html = fetchText("https://github.com/yangzhou521/AxsTweakKit/actions/workflows/notesreadonly.yml");
if (!html) { print("page -> NO DATA"); } else {
  var seen = {};
  var re = /"headSha":"([0-9a-f]{7,40})"[^}]{0,400}?"conclusion":"([a-z_]+)"/g;
  var m, n = 0;
  while ((m = re.exec(html)) !== null && n < 6) {
    var key = m[1].substring(0, 7) + m[2];
    if (seen[key]) { continue; }
    seen[key] = 1; n++;
    print("run sha=" + m[1].substring(0, 7) + " conclusion=" + m[2]);
  }
  var t = html.match(/([0-9]+) workflow run[s]?/);
  print("page hint: " + (t ? t[0] : "?"));
}
