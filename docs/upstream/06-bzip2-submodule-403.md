**Title:** Recursive submodule fetch fails: `Externals/bzip2` points at a gitlab URL returning HTTP 403

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`.*

A recursive submodule fetch fails outright, so nothing builds on a fresh clone.

`Externals/bzip2` is pinned to `https://gitlab.com/bzip2/bzip2.git`, which
returns **HTTP 403**.

`https://github.com/libarchive/bzip2.git` carries the **same pinned commit**,
`6a8690fc8d26c815e798c588f796eabe9d684cf0`, so redirecting the URL is
byte-identical to the current intent rather than a version substitution — worth
stressing, because a mirror that merely "has bzip2" would not be.

I work around it by rewriting the URL after `submodule init` and before
`submodule update`.
