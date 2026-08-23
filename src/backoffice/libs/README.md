# `libs/` — project-local Maven repository

Holds one artifact: **JInterface 1.16**, the Java side of the Erlang distribution
protocol, used by `erlang.ErlangBridge` to join the cluster as a hidden node.

The directory is laid out as a Maven repository and declared in `pom.xml` as
`voltshare-local`, so `mvn package` resolves it with no manual step.

## Why it is not a normal dependency

Maven Central publishes `org.erlang.otp:jinterface`, but its newest version is
**1.6.1**, released in 2011. It cannot connect to an OTP 29 node: the
distribution handshake gets no answer and `OtpNode.ping/2` returns false. This
was verified against a live `-sname` node — the same probe with a current
JInterface answers `PONG`.

The Windows OTP installer does not ship the compiled jar either (only the
JavaDoc), so it has to be built.

## How this jar was built

From the JInterface sources of the exact OTP release we run:

```bash
# 57 .java files, one package
curl -L "https://api.github.com/repos/erlang/otp/contents/lib/jinterface/java_src/com/ericsson/otp/erlang?ref=OTP-29.0.5"
# download each download_url into com/ericsson/otp/erlang/, then:
javac -d classes com/ericsson/otp/erlang/*.java
jar --create --file jinterface-1.16.jar -C classes com
```

Built with JDK 17, the same target as the back office.

On a machine with Docker the jar can also be lifted out of the image, which is
quicker:

```bash
docker run --rm erlang:29.0.5 cat /usr/local/lib/erlang/lib/jinterface-1.16/priv/OtpErlang.jar > jinterface-1.16.jar
```

## When to redo this

Only when the OTP version changes. Keep the jar, the directory name and the
`<version>` in `pom.xml` in step with `deploy/Dockerfile.erlang` — a JInterface
older than the cluster is exactly the failure this file exists to prevent.
