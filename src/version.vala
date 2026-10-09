/*
 * version.vala — 版本号
 *
 * 单独成文件，让核心引擎不必依赖 GUI 入口（main.vala）就能编译，
 * 这样自测程序可以只链接引擎模块。
 */
public const string APPMGR_VERSION = "1.0.0";
