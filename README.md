<div align="center">

![](docs/logo.svg)

# Phice

**Turn an iPhone into a MacBook-style trackpad**

In development · not released yet

</div>

---

A native iPhone app recognises the gestures and talks peer-to-peer to a tiny
agent on the Mac, which applies Apple's own pointer curves and posts the
events. No server between them. Every setting lives on the phone; the Mac agent
is meant to be forgotten.

## Building from source

```bash
swift test                     # the suite
cd Apps && xcodegen generate   # then build the PhiceMac and PhiceiOS schemes
```

Architecture, and the constraints that are not negotiable, are in
[CLAUDE.md](CLAUDE.md).

## The air mouse

The earlier Phice, an air mouse driven by a web page on the phone, is parked on
the [`python-air-mouse`](https://github.com/zupersun/phice/tree/python-air-mouse)
branch. Its last build is
[Phice 0.2.1](https://github.com/zupersun/phice/releases/tag/v0.2.1).

<div align="center">

MIT · © 2026 Jasper Sun

</div>
