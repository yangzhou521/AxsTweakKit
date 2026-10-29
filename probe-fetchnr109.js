// 文档提交重跑后，release 上的 1.0.9 资产被换成新构建的字节。下载它，用来和已装机、
// 已验证的那份比 dylib 哈希。写 /var/mobile/Documents（mobile 可写、root 可读）。
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');

var asset = "https://github.com/yangzhou521/AxsTweakKit/releases/download/notesreadonly-v1.0.9/com.unknown.notesreadonly_1.0.9_iphoneos-arm64e.deb";
var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(asset));
if (!data) {
  print("NO DATA");
} else {
  var path = "/var/mobile/Documents/nr109-rebuilt.deb";
  var ok = data.writeToFile_atomically_(path, true);
  print("wrote " + path + " ok=" + ok + " len=" + data.length());
}
