# Source provenance

Copyright 2026 Screenpunk, Inc. This repository starts with a curated snapshot of the universal app, device packages, public contracts and local setup tools. The predecessor public [Screenpunk repository](https://github.com/screenpunk-xyz/screenpunk) retains its existing history and releases. Mixed private service history is not imported here.

The migration preserves the existing software license and attribution. Changes to public software remain governed by Apache License 2.0; see LICENSE and NOTICE. The Google TV ADB implementation includes its original third-party license at `packages/ScreenpunkApple/Sources/ScreenpunkApple/Resources/ADB-LICENSE.txt`. Swift and Node dependency versions and origins are pinned in their lock files and retain their own licenses. Brand artwork follows its separate provenance and terms.

App storage and official bundle identity are preserved; extraction does not migrate user data. The private service consumes a checksummed release artifact of these public contracts and setup resources. Official releases select an immutable public source revision.
