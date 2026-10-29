// 查 1.0.9 release 资产现状（名字/大小/更新时间），确认文档提交那次重跑有没有换掉 deb。
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function fetch(url) { return NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url)); }
function text(data) {
  if (!data) { return null; }
  return String(NSString.alloc().initWithData_encoding_(data, 4));
}

var json = text(fetch("https://api.github.com/repos/yangzhou521/AxsTweakKit/releases/tags/notesreadonly-v1.0.9"));
if (!json) { print("api -> NO DATA"); } else {
  var re = /"(tag_name|name|size|created_at|updated_at|browser_download_url)":\s*("[^"]*"|\d+)/g;
  var m, n = 0;
  while ((m = re.exec(json)) !== null && n < 24) { n++; print(m[1] + " = " + m[2]); }
  if (n === 0) { print("no fields; head: " + json.substring(0, 200)); }
}

// 实际字节数（重下资产，和记录的 14704 B / sha256 对比用）
var data = fetch("https://github.com/yangzhou521/AxsTweakKit/releases/download/notesreadonly-v1.0.9/com.unknown.notesreadonly_1.0.9_iphoneos-arm64e.deb");
print("downloaded bytes = " + (data ? data.length() : "nil"));
