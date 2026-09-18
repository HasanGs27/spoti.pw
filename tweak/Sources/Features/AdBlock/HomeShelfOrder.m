#import "HomeShelfOrder.h"

// Match complete protobuf string fields, not substring hits inside playlist names.
// Bounded traversal deliberately fails closed for a new or unexpectedly large schema.
static BOOL scanTitles(NSData *data, NSUInteger depth, NSUInteger *budget, NSUInteger *flags) {
    if (!*budget || depth > 8) return NO;
    --*budget;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([text isEqualToString:@"Vos artistes préférés"]) { *flags |= 1; return YES; }
    if ([text isEqualToString:@"Lancer la lecture"]) { *flags |= 2; return YES; }
    NSArray<SGPBField *> *fields = SGPBParse(data);
    if (!fields) return YES; // Ordinary text or opaque payload, not a nested message.
    for (SGPBField *field in fields) {
        if (field.wire == 2 && !scanTitles(field.payload, depth + 1, budget, flags)) return NO;
    }
    return YES;
}

BOOL SGHomeOrderShelves(NSMutableArray<SGPBField *> *sections) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SGHomeArtistsFirstDisabled"] ||
        sections.count < 2 || sections.count > 256) return NO;
    NSUInteger artists = NSNotFound, play = NSNotFound, budget = 8192;
    for (NSUInteger i = 0; i < sections.count; i++) {
        SGPBField *section = sections[i];
        if (section.number != 1 || section.wire != 2) return NO;
        NSUInteger flags = 0;
        if (!scanTitles(section.payload, 0, &budget, &flags) || flags == 3) return NO;
        if (flags == 1) { if (artists != NSNotFound) return NO; artists = i; }
        if (flags == 2) { if (play != NSNotFound) return NO; play = i; }
    }
    if (artists == NSNotFound || play == NSNotFound || artists + 1 == play) return NO;
    SGPBField *shelf = sections[artists];
    [sections removeObjectAtIndex:artists];
    if (artists < play) --play;
    [sections insertObject:shelf atIndex:play];
    return YES;
}

#ifdef SG_HOME_ORDER_TEST
// Run the production function on complete, partial and ambiguous wire fixtures.
static SGPBField *shelf(NSString *title, uint64_t identifier) {
    NSData *heading = SGPBSerialize(@[SGPBString(2, title)]);
    return SGPBBytes(1, SGPBSerialize(@[SGPBVarint(1, identifier), SGPBBytes(3, heading),
        SGPBBytes(9, [NSData dataWithBytes:"\xff\x00" length:2])]));
}
int main(void) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SGHomeArtistsFirstDisabled"];
        SGPBField *a = shelf(@"Vos artistes préférés", 4), *p = shelf(@"Lancer la lecture", 2);
        SGPBField *first = shelf(@"Recent", 1), *middle = shelf(@"Unchanged", 3), *last = shelf(@"Last", 5);
        NSArray *original = @[first, p, middle, a, last];
        NSMutableArray *values = [original mutableCopy];
        NSArray *payloads = [original valueForKey:@"payload"];
        NSCAssert(SGHomeOrderShelves(values), @"must reorder");
        NSCAssert(([values isEqualToArray:@[first, a, p, middle, last]]), @"stable order");
        NSCAssert([[original valueForKey:@"payload"] isEqual:payloads], @"payloads unchanged");
        NSCAssert(!SGHomeOrderShelves(values), @"idempotent");
        NSArray *unchangedCases = @[@[first, p, last], @[first, a, last],
            @[a, p, shelf(@"Vos artistes préférés", 6)],
            @[a, p, shelf(@"Lancer la lecture", 7)],
            @[shelf(@"Playlist Vos artistes préférés", 8), p],
            @[SGPBVarint(1, 42), a, p]];
        for (NSArray *input in unchangedCases) {
            NSMutableArray *candidate = [input mutableCopy];
            NSCAssert(!SGHomeOrderShelves(candidate) && [candidate isEqual:input], @"must pass through");
        }
        values = [@[a, first, p, last] mutableCopy];
        NSCAssert((SGHomeOrderShelves(values) && [values isEqualToArray:@[first, a, p, last]]), @"earlier shelf");
        SGPBField *both = SGPBBytes(1, SGPBSerialize(@[SGPBString(2, @"Vos artistes préférés"), SGPBString(3, @"Lancer la lecture")]));
        values = [@[both, last] mutableCopy];
        NSCAssert(!SGHomeOrderShelves(values), @"ambiguous section");
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SGHomeArtistsFirstDisabled"];
        values = [original mutableCopy];
        NSCAssert(!SGHomeOrderShelves(values) && [values isEqual:original], @"rollback switch");
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SGHomeArtistsFirstDisabled"];
        NSLog(@"Home shelf ordering: all fixture checks passed");
    }
    return 0;
}
#endif
