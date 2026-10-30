load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
swift_library(
    name = "NoveoTransport",
    module_name = "NoveoTransport",
    srcs = glob(["Sources/**/*.swift"]),
    visibility = ["//visibility:public"],
)
swift_test(
    name = "NoveoTransportTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":NoveoTransport"],
)
