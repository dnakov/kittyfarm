// Adapted from Aayush9029/doq, MIT License.
// https://github.com/Aayush9029/doq
#import "DocumentationSemanticBridge.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>

static NSString *const DoqDocsErrorDomain = @"doq.docs";

typedef NS_ENUM(NSInteger, DoqDocsErrorCode) {
    DoqDocsErrorUnavailable = 1,
    DoqDocsErrorOperationFailed = 2,
    DoqDocsErrorInvalidResponse = 3,
};

static NSString *DoqDocsCopyString(NSString *value) {
    return value ?: @"";
}

static NSError *DoqDocsError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:DoqDocsErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

static char *DoqDocsCStringFromString(NSString *value) {
    NSData *data = [DoqDocsCopyString(value) dataUsingEncoding:NSUTF8StringEncoding];
    char *buffer = malloc(data.length + 1);
    if (buffer == NULL) {
        return NULL;
    }
    memcpy(buffer, data.bytes, data.length);
    buffer[data.length] = '\0';
    return buffer;
}

static void DoqDocsSetError(char **errOut, NSError *error) {
    if (errOut == NULL) {
        return;
    }
    *errOut = DoqDocsCStringFromString(error.localizedDescription ?: @"Unknown error");
}

static id DoqDocsAlloc(Class cls) {
    return ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("alloc"));
}

static id DoqDocsInitWithObject(id object, SEL selector, id arg) {
    return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, arg);
}

static id DoqDocsInitWithObjectAndObject(id object, SEL selector, id arg1, id arg2) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(object, selector, arg1, arg2);
}

static id DoqDocsClassObjectCall(Class cls, SEL selector) {
    return ((id (*)(Class, SEL))objc_msgSend)(cls, selector);
}

static BOOL DoqDocsLoadBundle(NSString *path, NSError **error) {
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (bundle == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorUnavailable, [NSString stringWithFormat:@"Framework bundle missing at %@", path]);
        }
        return NO;
    }

    if (![bundle load]) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorUnavailable, [NSString stringWithFormat:@"Failed to load framework at %@", path]);
        }
        return NO;
    }
    return YES;
}

static BOOL DoqDocsEnsureFrameworks(NSError **error) {
    static dispatch_once_t onceToken;
    static NSError *cachedError;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            NSError *localError = nil;
            if (!DoqDocsLoadBundle(@"/System/Library/PrivateFrameworks/MediaAnalysisServices.framework", &localError)) {
                cachedError = localError;
                return;
            }
            DoqDocsLoadBundle(@"/System/Library/PrivateFrameworks/VectorSearch.framework", &localError);
            cachedError = localError;
        }
    });

    if (cachedError != nil) {
        if (error != NULL) {
            *error = cachedError;
        }
        return NO;
    }
    return YES;
}

static BOOL DoqDocsIsSupportedOS(NSError **error) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion >= 26) {
        return YES;
    }
    if (error != NULL) {
        *error = DoqDocsError(DoqDocsErrorUnavailable, @"Semantic docs search requires macOS 26 or later");
    }
    return NO;
}

static NSURL *DoqDocsDatabaseDirectoryURL(NSError **error) {
    NSURL *assetRootURL = [NSURL fileURLWithPath:@"/System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation" isDirectory:YES];
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:assetRootURL includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:error];
    if (contents == nil) {
        if (error != NULL && *error == nil) {
            *error = DoqDocsError(DoqDocsErrorUnavailable, [NSString stringWithFormat:@"Documentation asset root is missing at %@", assetRootURL.path]);
        }
        return nil;
    }

    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    for (NSURL *url in contents) {
        if (![[url pathExtension] isEqualToString:@"asset"]) {
            continue;
        }

        NSURL *indexURL = [[[url URLByAppendingPathComponent:@"AssetData" isDirectory:YES] URLByAppendingPathComponent:@"documentation-db" isDirectory:YES] URLByAppendingPathComponent:@"index.sql"];
        if ([[NSFileManager defaultManager] isReadableFileAtPath:indexURL.path]) {
            [candidates addObject:url];
        }
    }

    [candidates sortUsingComparator:^NSComparisonResult(NSURL *lhs, NSURL *rhs) {
        NSDate *leftDate = nil;
        NSDate *rightDate = nil;
        [lhs getResourceValue:&leftDate forKey:NSURLContentModificationDateKey error:nil];
        [rhs getResourceValue:&rightDate forKey:NSURLContentModificationDateKey error:nil];
        return [rightDate compare:leftDate];
    }];

    NSURL *assetURL = candidates.firstObject;
    if (assetURL == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorUnavailable, @"No AppleDeveloperDocumentation asset with a readable index was found");
        }
        return nil;
    }

    return [[assetURL URLByAppendingPathComponent:@"AssetData" isDirectory:YES] URLByAppendingPathComponent:@"documentation-db" isDirectory:YES];
}

static NSData *DoqDocsFloat32DataFromFloat16Data(NSData *data, NSError **error) {
    if (data.length == 0 || data.length % sizeof(uint16_t) != 0) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Embedding data was empty or malformed");
        }
        return nil;
    }

    NSUInteger count = data.length / sizeof(uint16_t);
    NSMutableData *float32 = [NSMutableData dataWithLength:count * sizeof(float)];
    const uint16_t *input = data.bytes;
    float *output = float32.mutableBytes;

    for (NSUInteger i = 0; i < count; i++) {
        uint16_t h = input[i];
        uint32_t sign = (uint32_t)(h & 0x8000) << 16;
        uint32_t exp = (h & 0x7C00) >> 10;
        uint32_t mant = h & 0x03FF;
        uint32_t bits = 0;

        if (exp == 0) {
            if (mant == 0) {
                bits = sign;
            } else {
                exp = 127 - 15 + 1;
                while ((mant & 0x0400) == 0) {
                    mant <<= 1;
                    exp--;
                }
                mant &= 0x03FF;
                bits = sign | (exp << 23) | (mant << 13);
            }
        } else if (exp == 0x1F) {
            bits = sign | 0x7F800000 | (mant << 13);
        } else {
            bits = sign | ((exp + (127 - 15)) << 23) | (mant << 13);
        }

        memcpy(&output[i], &bits, sizeof(bits));
    }

    return float32;
}

static NSData *DoqDocsEmbeddingVector(NSString *text, NSError **error) {
    Class serviceClass = NSClassFromString(@"MADService");
    Class requestClass = NSClassFromString(@"MADTextEmbeddingRequest");
    Class inputClass = NSClassFromString(@"MADTextInput");
    if (serviceClass == nil || requestClass == nil || inputClass == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorUnavailable, @"MediaAnalysisServices classes are unavailable");
        }
        return nil;
    }

    id service = DoqDocsClassObjectCall(serviceClass, sel_registerName("service"));
    if (service == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create MADService");
        }
        return nil;
    }

    id request = [DoqDocsAlloc(requestClass) init];
    id input = DoqDocsInitWithObject(DoqDocsAlloc(inputClass), sel_registerName("initWithText:"), text);
    if (request == nil || input == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create embedding request objects");
        }
        return nil;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL completed = NO;
    void (^completion)(void) = ^{
        completed = YES;
        dispatch_semaphore_signal(sem);
    };

    @try {
        int32_t requestID = ((int32_t (*)(id, SEL, NSArray *, NSArray *, id))objc_msgSend)(
            service,
            sel_registerName("performRequests:textInputs:completionHandler:"),
            @[request],
            @[input],
            completion
        );
        if (requestID < 0) {
            if (error != NULL) {
                *error = DoqDocsError(DoqDocsErrorOperationFailed, @"MediaAnalysisServices returned an invalid request id");
            }
            return nil;
        }
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorOperationFailed, exception.reason ?: @"MediaAnalysisServices raised an exception");
        }
        return nil;
    }

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC));
    if (!completed && dispatch_semaphore_wait(sem, timeout) != 0) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Timed out waiting for embedding generation");
        }
        return nil;
    }

    NSArray *results = [request valueForKey:@"embeddingResults"];
    id firstResult = results.firstObject;
    NSData *embeddingData = [firstResult valueForKey:@"embeddingData"];
    if (firstResult == nil || ![embeddingData isKindOfClass:[NSData class]]) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorOperationFailed, @"MediaAnalysisServices completed without embedding data");
        }
        return nil;
    }

    return DoqDocsFloat32DataFromFloat16Data(embeddingData, error);
}

static id DoqDocsColumnType(NSError **error) {
    Class cls = NSClassFromString(@"VSKColumnType");
    id object = DoqDocsInitWithObject(DoqDocsAlloc(cls), sel_registerName("initWithStringDefaultValue:"), @"");
    if (object == nil && error != NULL) {
        *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create VSKColumnType");
    }
    return object;
}

static id DoqDocsAttribute(NSString *name, NSError **error) {
    Class cls = NSClassFromString(@"VSKAttribute");
    id columnType = DoqDocsColumnType(error);
    if (columnType == nil) {
        return nil;
    }

    id object = DoqDocsInitWithObjectAndObject(DoqDocsAlloc(cls), sel_registerName("initWithName:columnType:"), name, columnType);
    if (object == nil && error != NULL) {
        *error = DoqDocsError(DoqDocsErrorOperationFailed, [NSString stringWithFormat:@"Failed to create VSKAttribute %@", name]);
    }
    return object;
}

static id DoqDocsDatabaseValue(NSString *value, NSError **error) {
    Class cls = NSClassFromString(@"VSKDatabaseValue");
    id object = DoqDocsInitWithObject(DoqDocsAlloc(cls), sel_registerName("initWithStringValue:"), value);
    if (object == nil && error != NULL) {
        *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create VSKDatabaseValue");
    }
    return object;
}

static id DoqDocsDisjunctiveFilter(NSString *value, NSError **error) {
    Class cls = NSClassFromString(@"VSKDisjunctiveFilter");
    id databaseValue = DoqDocsDatabaseValue(value, error);
    if (databaseValue == nil) {
        return nil;
    }

    id object = ((id (*)(id, SEL, int64_t, id))objc_msgSend)(
        DoqDocsAlloc(cls),
        sel_registerName("initWithOperator:value:"),
        (int64_t)2,
        databaseValue
    );
    if (object == nil && error != NULL) {
        *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create VSKDisjunctiveFilter");
    }
    return object;
}

static id DoqDocsFilter(NSString *attributeName, NSArray<NSString *> *values, NSError **error) {
    NSMutableArray *trimmed = [NSMutableArray array];
    for (NSString *value in values) {
        NSString *normalized = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (normalized.length > 0) {
            [trimmed addObject:normalized];
        }
    }
    if (trimmed.count == 0) {
        return nil;
    }

    id attribute = DoqDocsAttribute(attributeName, error);
    if (attribute == nil) {
        return nil;
    }

    NSMutableArray *disjunctiveFilters = [NSMutableArray arrayWithCapacity:trimmed.count];
    for (NSString *value in trimmed) {
        id filter = DoqDocsDisjunctiveFilter(value, error);
        if (filter == nil) {
            return nil;
        }
        [disjunctiveFilters addObject:filter];
    }

    Class cls = NSClassFromString(@"VSKFilter");
    id object = DoqDocsInitWithObjectAndObject(DoqDocsAlloc(cls), sel_registerName("initWithAttribute:disjunctiveFilters:"), attribute, disjunctiveFilters);
    if (object == nil && error != NULL) {
        *error = DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create VSKFilter");
    }
    return object;
}

static NSArray *DoqDocsSelectedAttributes(BOOL omitContent, NSError **error) {
    NSMutableArray *selected = [NSMutableArray array];
    for (NSString *name in @[@"framework", @"type", @"title"]) {
        id attribute = DoqDocsAttribute(name, error);
        if (attribute == nil) {
            return nil;
        }
        [selected addObject:attribute];
    }
    if (!omitContent) {
        id attribute = DoqDocsAttribute(@"content", error);
        if (attribute == nil) {
            return nil;
        }
        [selected addObject:attribute];
    }
    return selected;
}

static NSArray *DoqDocsExactLookupAttributes(NSError **error) {
    NSMutableArray *selected = [NSMutableArray array];
    for (NSString *name in @[@"framework", @"type", @"title", @"content"]) {
        id attribute = DoqDocsAttribute(name, error);
        if (attribute == nil) {
            return nil;
        }
        [selected addObject:attribute];
    }
    return selected;
}

static id DoqDocsCreateClient(NSError **error) {
    NSURL *databaseURL = DoqDocsDatabaseDirectoryURL(error);
    if (databaseURL == nil) {
        return nil;
    }

    Class configClass = NSClassFromString(@"VSKConfig");
    Class clientClass = NSClassFromString(@"VSKClient");
    if (configClass == nil || clientClass == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorUnavailable, @"VectorSearch classes are unavailable");
        }
        return nil;
    }

    NSError *configError = nil;
    id config = ((id (*)(id, SEL, NSURL *, BOOL, NSNumber *, BOOL, NSError **))objc_msgSend)(
        DoqDocsAlloc(configClass),
        sel_registerName("initWithBaseDirectory:includePayload:numberOfProbes:readOnly:error:"),
        databaseURL,
        NO,
        @8,
        YES,
        &configError
    );
    if (config == nil || configError != nil) {
        if (error != NULL) {
            *error = configError ?: DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create VSKConfig");
        }
        return nil;
    }

    NSError *clientError = nil;
    id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        DoqDocsAlloc(clientClass),
        sel_registerName("initWithConfig:error:"),
        config,
        &clientError
    );
    if (client == nil || clientError != nil) {
        if (error != NULL) {
            *error = clientError ?: DoqDocsError(DoqDocsErrorOperationFailed, @"Failed to create VSKClient");
        }
        return nil;
    }

    return client;
}

static NSMutableDictionary *DoqDocsAttributesDictionary(NSDictionary *attributes) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (id key in attributes) {
        NSString *name = [key respondsToSelector:sel_registerName("getName")] ? ((id (*)(id, SEL))objc_msgSend)(key, sel_registerName("getName")) : nil;
        NSString *value = [attributes[key] respondsToSelector:sel_registerName("getStringValue")] ? ((id (*)(id, SEL))objc_msgSend)(attributes[key], sel_registerName("getStringValue")) : nil;
        if (name.length > 0 && value != nil) {
            result[name] = value;
        }
    }
    return result;
}

static NSMutableDictionary *DoqDocsSearchHitFromResult(id rawResult, NSError **error) {
    NSString *identifier = [rawResult valueForKey:@"stringIdentifier"];
    id scoreValue = [rawResult valueForKey:@"value"];
    NSDictionary *attributes = [rawResult valueForKey:@"attributes"];
    if (identifier.length == 0 || attributes == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorInvalidResponse, @"Vector search returned an unexpected response");
        }
        return nil;
    }

    double score = 0;
    if ([scoreValue isKindOfClass:[NSNumber class]]) {
        score = [scoreValue doubleValue];
    }

    NSMutableDictionary *result = [@{
        @"id": identifier,
        @"score": @(score),
    } mutableCopy];

    NSMutableDictionary *mapped = DoqDocsAttributesDictionary(attributes);
    if (mapped[@"framework"] != nil) {
        result[@"framework"] = mapped[@"framework"];
    }
    if (mapped[@"type"] != nil) {
        result[@"kind"] = mapped[@"type"];
    }
    if (mapped[@"title"] != nil) {
        result[@"title"] = mapped[@"title"];
    }
    if (mapped[@"content"] != nil) {
        result[@"content"] = mapped[@"content"];
    }
    return result;
}

static NSMutableDictionary *DoqDocsEntryFromAsset(id rawAsset, NSError **error) {
    NSString *identifier = [rawAsset valueForKey:@"stringIdentifier"];
    NSDictionary *attributes = [rawAsset valueForKey:@"attributes"];
    if (identifier.length == 0 || attributes == nil) {
        if (error != NULL) {
            *error = DoqDocsError(DoqDocsErrorInvalidResponse, @"Vector search asset lookup returned an unexpected response");
        }
        return nil;
    }

    NSMutableDictionary *result = [@{@"id": identifier} mutableCopy];
    NSMutableDictionary *mapped = DoqDocsAttributesDictionary(attributes);
    if (mapped[@"framework"] != nil) {
        result[@"framework"] = mapped[@"framework"];
    }
    if (mapped[@"type"] != nil) {
        result[@"kind"] = mapped[@"type"];
    }
    if (mapped[@"title"] != nil) {
        result[@"title"] = mapped[@"title"];
    }
    if (mapped[@"content"] != nil) {
        result[@"content"] = mapped[@"content"];
    }
    return result;
}

static NSArray<NSString *> *DoqDocsOrderedUniqueIdentifiers(NSArray<NSString *> *identifiers) {
    NSMutableOrderedSet *ordered = [NSMutableOrderedSet orderedSet];
    for (NSString *identifier in identifiers) {
        if (identifier.length > 0) {
            [ordered addObject:identifier];
        }
    }
    return ordered.array;
}

static NSArray *DoqDocsAssetsForIdentifiers(id client, NSArray<NSString *> *identifiers, NSArray *selectedAttributes, NSError **error) {
    if (identifiers.count == 0) {
        return @[];
    }

    NSError *lookupError = nil;
    id assets = ((id (*)(id, SEL, NSArray *, NSArray *, id, BOOL, NSArray *, NSError **))objc_msgSend)(
        client,
        sel_registerName("stringIdentifiedAssetsWithIdentifiers:attributeFilters:pagination:includeVectors:selectAttributes:error:"),
        identifiers,
        nil,
        nil,
        NO,
        selectedAttributes,
        &lookupError
    );
    if (assets == nil || lookupError != nil) {
        if (error != NULL) {
            *error = lookupError ?: DoqDocsError(DoqDocsErrorOperationFailed, @"Asset lookup failed");
        }
        return nil;
    }
    return assets;
}

static NSArray *DoqDocsHydrateHits(id client, NSArray *hits, NSArray *selectedAttributes, NSError **error) {
    NSMutableArray<NSString *> *attributeNames = [NSMutableArray arrayWithCapacity:selectedAttributes.count];
    for (id attribute in selectedAttributes) {
        NSString *name = [attribute respondsToSelector:sel_registerName("getName")] ? ((id (*)(id, SEL))objc_msgSend)(attribute, sel_registerName("getName")) : nil;
        if (name.length > 0) {
            [attributeNames addObject:name];
        }
    }

    NSMutableArray<NSString *> *incomplete = [NSMutableArray array];
    for (NSDictionary *hit in hits) {
        for (NSString *attributeName in attributeNames) {
            NSString *mappedKey = [attributeName isEqualToString:@"type"] ? @"kind" : attributeName;
            NSString *value = hit[mappedKey];
            if (value == nil || value.length == 0) {
                [incomplete addObject:hit[@"id"]];
                break;
            }
        }
    }

    NSArray<NSString *> *uniqueIdentifiers = DoqDocsOrderedUniqueIdentifiers(incomplete);
    if (uniqueIdentifiers.count == 0) {
        return hits;
    }

    NSArray *assets = DoqDocsAssetsForIdentifiers(client, uniqueIdentifiers, selectedAttributes, error);
    if (assets == nil) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *entriesByID = [NSMutableDictionary dictionary];
    for (id asset in assets) {
        NSMutableDictionary *entry = DoqDocsEntryFromAsset(asset, error);
        if (entry == nil) {
            return nil;
        }
        entriesByID[entry[@"id"]] = entry;
    }

    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:hits.count];
    for (NSDictionary *hit in hits) {
        NSMutableDictionary *copy = [hit mutableCopy];
        NSDictionary *hydrated = entriesByID[hit[@"id"]];
        for (NSString *key in @[@"framework", @"kind", @"title", @"content"]) {
            NSString *existing = copy[key];
            NSString *candidate = hydrated[key];
            if ((existing == nil || existing.length == 0) && candidate.length > 0) {
                copy[key] = candidate;
            }
        }
        [merged addObject:copy];
    }
    return merged;
}

static NSArray<NSString *> *DoqDocsTopicIdentifiers(id client, NSError **error) {
    id filter = DoqDocsFilter(@"type", @[@"topic"], error);
    if (filter == nil) {
        return nil;
    }

    NSError *lookupError = nil;
    id result = ((id (*)(id, SEL, NSArray *, NSError **))objc_msgSend)(
        client,
        sel_registerName("stringIdentifiersApplyingFilters:error:"),
        @[filter],
        &lookupError
    );
    if (result == nil || lookupError != nil) {
        if (error != NULL) {
            *error = lookupError ?: DoqDocsError(DoqDocsErrorOperationFailed, @"Identifier lookup failed");
        }
        return nil;
    }
    return DoqDocsOrderedUniqueIdentifiers(result);
}

static NSDictionary<NSString *, NSArray<NSString *> *> *DoqDocsDescendantsByParent(id client, NSArray<NSString *> *parentIDs, NSError **error) {
    NSArray<NSString *> *topics = DoqDocsTopicIdentifiers(client, error);
    if (topics == nil || topics.count == 0) {
        return @{};
    }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *descendants = [NSMutableDictionary dictionary];
    for (NSString *parentID in DoqDocsOrderedUniqueIdentifiers(parentIDs)) {
        if ([parentID containsString:@"#"]) {
            continue;
        }

        NSString *prefix = [parentID stringByAppendingString:@"#"];
        NSMutableArray<NSString *> *children = [NSMutableArray array];
        for (NSString *topicID in topics) {
            if ([topicID hasPrefix:prefix]) {
                [children addObject:topicID];
            }
        }
        if (children.count > 0) {
            descendants[parentID] = children;
        }
    }
    return descendants;
}

static NSArray *DoqDocsAppendDescendantContents(id client, NSArray *hits, NSDictionary<NSString *, NSArray<NSString *> *> *descendantsByParent, NSArray *selectedAttributes, NSError **error) {
    NSMutableArray<NSString *> *allDescendants = [NSMutableArray array];
    for (NSArray<NSString *> *descendants in descendantsByParent.allValues) {
        [allDescendants addObjectsFromArray:descendants];
    }

    NSArray<NSString *> *uniqueDescendants = DoqDocsOrderedUniqueIdentifiers(allDescendants);
    if (uniqueDescendants.count == 0) {
        return hits;
    }

    NSArray *assets = DoqDocsAssetsForIdentifiers(client, uniqueDescendants, selectedAttributes, error);
    if (assets == nil) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *contentByID = [NSMutableDictionary dictionary];
    for (id asset in assets) {
        NSMutableDictionary *entry = DoqDocsEntryFromAsset(asset, error);
        if (entry == nil) {
            return nil;
        }
        NSString *content = entry[@"content"];
        if (content.length > 0) {
            contentByID[entry[@"id"]] = content;
        }
    }

    NSMutableArray *expanded = [NSMutableArray arrayWithCapacity:hits.count];
    for (NSDictionary *hit in hits) {
        NSMutableDictionary *copy = [hit mutableCopy];
        NSArray<NSString *> *descendants = descendantsByParent[hit[@"id"]];
        if (descendants.count > 0) {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            NSString *content = copy[@"content"];
            if (content.length > 0) {
                [parts addObject:content];
            }
            for (NSString *identifier in descendants) {
                NSString *descendantContent = contentByID[identifier];
                if (descendantContent.length > 0) {
                    [parts addObject:descendantContent];
                }
            }
            if (parts.count > 0) {
                copy[@"content"] = [parts componentsJoinedByString:@"\n\n"];
            }
        }
        [expanded addObject:copy];
    }
    return expanded;
}

static NSArray *DoqDocsDeduplicateHits(NSArray *hits, NSDictionary<NSString *, NSArray<NSString *> *> *descendantsByParent) {
    NSMutableSet<NSString *> *descendants = [NSMutableSet set];
    for (NSArray<NSString *> *children in descendantsByParent.allValues) {
        [descendants addObjectsFromArray:children];
    }
    if (descendants.count == 0) {
        return hits;
    }

    NSMutableArray *deduplicated = [NSMutableArray arrayWithCapacity:hits.count];
    for (NSDictionary *hit in hits) {
        if (![descendants containsObject:hit[@"id"]]) {
            [deduplicated addObject:hit];
        }
    }
    return deduplicated;
}

static NSArray<NSString *> *DoqDocsJSONArray(const char *jsonCString) {
    if (jsonCString == NULL) {
        return @[];
    }
    NSData *data = [[NSString stringWithUTF8String:jsonCString] dataUsingEncoding:NSUTF8StringEncoding];
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    return value;
}

static char *DoqDocsJSONString(id object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil) {
        return NULL;
    }
    return DoqDocsCStringFromString([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}

int doq_docs_available(char **err_out) {
    @autoreleasepool {
        NSError *error = nil;
        if (!DoqDocsIsSupportedOS(&error) || !DoqDocsEnsureFrameworks(&error) || DoqDocsDatabaseDirectoryURL(&error) == nil) {
            DoqDocsSetError(err_out, error);
            return 0;
        }
        return 1;
    }
}

char *doq_docs_search_json(const char *query, const char *frameworks_json, const char *kinds_json, int limit, bool omit_content, char **err_out) {
    @autoreleasepool {
        @try {
            NSError *error = nil;
            if (!DoqDocsIsSupportedOS(&error) || !DoqDocsEnsureFrameworks(&error)) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSString *queryString = [NSString stringWithUTF8String:query ?: ""];
            if (queryString.length == 0) {
                return DoqDocsJSONString(@[], &error);
            }

            id client = DoqDocsCreateClient(&error);
            if (client == nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSData *vector = DoqDocsEmbeddingVector(queryString, &error);
            if (vector == nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSMutableArray *filters = [NSMutableArray array];
            id frameworkFilter = DoqDocsFilter(@"framework", DoqDocsJSONArray(frameworks_json), &error);
            if (frameworkFilter != nil) {
                [filters addObject:frameworkFilter];
            }
            if (error != nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            id kindFilter = DoqDocsFilter(@"type", DoqDocsJSONArray(kinds_json), &error);
            if (kindFilter != nil) {
                [filters addObject:kindFilter];
            }
            if (error != nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSArray *selectedAttributes = DoqDocsSelectedAttributes(omit_content, &error);
            if (selectedAttributes == nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSError *searchError = nil;
            id rawResults = ((id (*)(id, SEL, NSData *, NSArray *, NSArray *, NSArray *, int32_t, BOOL, BOOL, NSNumber *, NSNumber *, NSNumber *, NSError **))objc_msgSend)(
                client,
                sel_registerName("searchByVector:stringIdentifiers:attributeFilters:selectAttributes:limit:fullScan:includePayload:numberOfProbes:batchSize:numConcurrentReaders:error:"),
                vector,
                nil,
                filters.count > 0 ? filters : nil,
                selectedAttributes,
                (int32_t)(limit > 0 ? limit : 10),
                YES,
                NO,
                @8,
                @64,
                @2,
                &searchError
            );
            if (rawResults == nil || searchError != nil) {
                DoqDocsSetError(err_out, searchError ?: DoqDocsError(DoqDocsErrorOperationFailed, @"Vector search failed"));
                return NULL;
            }

            NSMutableArray *hits = [NSMutableArray array];
            for (id rawResult in rawResults) {
                NSMutableDictionary *hit = DoqDocsSearchHitFromResult(rawResult, &error);
                if (hit == nil) {
                    DoqDocsSetError(err_out, error);
                    return NULL;
                }
                [hits addObject:hit];
            }

            hits = [[DoqDocsHydrateHits(client, hits, selectedAttributes, &error) mutableCopy] ?: hits mutableCopy];
            if (error != nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSDictionary<NSString *, NSArray<NSString *> *> *descendantsByParent = DoqDocsDescendantsByParent(client, [hits valueForKey:@"id"], &error);
            if (error != nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            if (!omit_content) {
                NSArray *expanded = DoqDocsAppendDescendantContents(client, hits, descendantsByParent, selectedAttributes, &error);
                if (expanded == nil) {
                    DoqDocsSetError(err_out, error);
                    return NULL;
                }
                hits = [expanded mutableCopy];
            }

            hits = [[DoqDocsDeduplicateHits(hits, descendantsByParent) mutableCopy] ?: hits mutableCopy];
            return DoqDocsJSONString(hits, &error);
        } @catch (NSException *exception) {
            DoqDocsSetError(err_out, DoqDocsError(DoqDocsErrorOperationFailed, exception.reason ?: @"Semantic docs bridge raised an exception"));
            return NULL;
        }
    }
}

char *doq_docs_get_json(const char *identifier, char **err_out) {
    @autoreleasepool {
        @try {
            NSError *error = nil;
            if (!DoqDocsIsSupportedOS(&error) || !DoqDocsEnsureFrameworks(&error)) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSString *identifierString = [NSString stringWithUTF8String:identifier ?: ""];
            if (identifierString.length == 0) {
                DoqDocsSetError(err_out, DoqDocsError(DoqDocsErrorOperationFailed, @"Documentation identifier is required"));
                return NULL;
            }

            id client = DoqDocsCreateClient(&error);
            if (client == nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSArray *selectedAttributes = DoqDocsExactLookupAttributes(&error);
            if (selectedAttributes == nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSArray *assets = DoqDocsAssetsForIdentifiers(client, @[identifierString], selectedAttributes, &error);
            if (assets == nil || assets.count == 0) {
                DoqDocsSetError(err_out, error ?: DoqDocsError(DoqDocsErrorOperationFailed, [NSString stringWithFormat:@"No documentation entry was found for %@", identifierString]));
                return NULL;
            }

            NSMutableDictionary *entry = DoqDocsEntryFromAsset(assets.firstObject, &error);
            if (entry == nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSDictionary<NSString *, NSArray<NSString *> *> *descendantsByParent = DoqDocsDescendantsByParent(client, @[identifierString], &error);
            if (error != nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSArray *expanded = DoqDocsAppendDescendantContents(client, @[entry], descendantsByParent, selectedAttributes, &error);
            if (expanded == nil) {
                DoqDocsSetError(err_out, error);
                return NULL;
            }

            NSDictionary *resolved = expanded.firstObject ?: entry;
            return DoqDocsJSONString(resolved, &error);
        } @catch (NSException *exception) {
            DoqDocsSetError(err_out, DoqDocsError(DoqDocsErrorOperationFailed, exception.reason ?: @"Semantic docs bridge raised an exception"));
            return NULL;
        }
    }
}

void doq_docs_free(char *ptr) {
    free(ptr);
}
