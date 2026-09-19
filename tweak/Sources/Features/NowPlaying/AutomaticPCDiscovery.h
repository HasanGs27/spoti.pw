#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Finds only the already-paired PC. Exactly one main-queue completion, within
// eight seconds. A fresh HMAC proof is verified before returning a private URL.
FOUNDATION_EXPORT void SGAutomaticDiscoverPC(NSURL *pairedRoot, void (^completion)(NSURL * _Nullable root));
NS_ASSUME_NONNULL_END
