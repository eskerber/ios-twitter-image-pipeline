//
//  UIImage+TIPAdditions.m
//  TwitterImagePipeline
//
//  Created on 9/6/16.
//  Copyright © 2016 Twitter. All rights reserved.
//

#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

#import "TIP_Project.h"
#import "TIPError.h"
#import "TIPGlobalConfiguration+Project.h"
#import "TIPImageUtils.h"
#import "UIImage+TIPAdditions.h"

NS_ASSUME_NONNULL_BEGIN

static NSDictionary *TIPImageWritingProperties(UIImage *image,
                                               NSString *type,
                                               TIPImageEncodingOptions options,
                                               float quality,
                                               NSNumber * __nullable animationLoopCount,
                                               NSNumber * __nullable animationDuration,
                                               BOOL isGlobalProperties);
static CGImageRef __nullable TIPCGImageCreateGrayscale(CGImageRef __nullable imageRef);

@implementation UIImage (TIPAdditions)

#pragma mark Inferred Properties

- (CGSize)tip_dimensions
{
    return TIPDimensionsFromImage(self);
}

- (CGSize)tip_pointSize
{
    return TIPSizeByAdjustingScale(self.size, self.scale, [UIScreen mainScreen].scale);
}

- (NSUInteger)tip_estimatedSizeInBytes
{
    // Often an image can have additional bytes as a buffer per row of pixels.
    // Getting the true byte size will be most accurate.

    const NSUInteger bytesPerRow = self.CGImage ? CGImageGetBytesPerRow(self.CGImage) : 0;
    if (!bytesPerRow) {
        // unknown bytes per row, guesstimate
        return TIPEstimateMemorySizeOfImageWithSettings(self.size, self.scale, 4 /* Guess RGB+A == 4 bytes */, self.images.count);
    }

    const NSUInteger rowCount = (NSUInteger)(self.size.height * self.scale) * MAX((NSUInteger)1, self.images.count);
    return bytesPerRow * rowCount;
}

- (NSUInteger)tip_imageCountBasedOnImageType:(nullable NSString *)type
{
    if (!type || [type isEqualToString:TIPImageTypeGIF] || [type isEqualToString:TIPImageTypePNG]) {
        return MAX((NSUInteger)1, self.images.count);
    }

    return 1;
}

- (BOOL)tip_hasAlpha:(BOOL)inspectPixels
{
    if (self.images.count > 0) {
        UIImage *image = self.images.firstObject;
        return image ? [image tip_hasAlpha:inspectPixels] : YES /* assume alpha */;
    }

    if (self.CGImage) {
        return TIPCGImageHasAlpha(self.CGImage, inspectPixels);
    } else if (self.CIImage) {
        return TIPCIImageHasAlpha(self.CIImage, inspectPixels);
    }

    return YES; // just assume alpha
}

- (BOOL)tip_usesWideGamutColorSpace
{
    if (!TIPMainScreenSupportsWideColorGamut()) {
        // don't have support on this device, quick return
        return NO;
    }

    if (tip_available_ios_10) {
        // iOS 10 and above required for using P3 on images
    } else {
        return NO;
    }

    if (self.images.count > 0) {
        // animation, just check first image
        UIImage *image = self.images.firstObject;
        return image ? [image tip_usesWideGamutColorSpace] : NO /* assume sRGB */;
    }

    CGImageRef cgImage = self.CGImage;
    if (!cgImage) {
        return NO; // assume sRGB
    }

    CGColorSpaceRef colorSpace = CGImageGetColorSpace(cgImage);
    if (!CGColorSpaceIsWideGamutRGB(colorSpace)) {
        return NO;
    }

    return YES;
}

#pragma mark Inspection Methods

- (NSString *)tip_recommendedImageType:(TIPRecommendedImageTypeOptions)options
{
    if (self.images.count > 1) {
        return TIPImageTypeGIF;
    }

    BOOL alpha = NO;
    if (TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPRecommendedImageTypeAssumeAlpha)) {
        alpha = YES;
    } else if (TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPRecommendedImageTypeAssumeNoAlpha)) {
        alpha = NO;
    } else {
        alpha = [self tip_hasAlpha:YES];
    }
    const BOOL progressive = TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPRecommendedImageTypePreferProgressive);
    const BOOL lossy = TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPRecommendedImageTypePermitLossy);

    if (alpha) {
        if (lossy) {
            return TIPImageTypePNG; /* PNG for now, might want JPEG2000 */
        }
        if (progressive) {
            return TIPImageTypePNG; /* PNG for now */
        }

        return TIPImageTypePNG;
    }

    if (progressive) {
        return TIPImageTypeJPEG;
    }

    return TIPImageTypeJPEG;
}

- (BOOL)tip_matchesTargetDimensions:(CGSize)targetDimensions contentMode:(UIViewContentMode)targetContentMode
{
    return TIPSizeMatchesTargetSizing([self tip_dimensions], targetDimensions, targetContentMode, 1);
}

#pragma mark Transform Methods

- (nullable UIImage *)tip_imageWithRenderFormatting:(nullable TIPImageRenderFormattingBlock NS_NOESCAPE)formatBlock
                                             render:(nonnull TIPImageRenderBlock NS_NOESCAPE)renderBlock
{
    return TIPRenderImage(self, formatBlock, renderBlock);
}

// below code works but is unused since the UIKit method of scaling is preferred
#if 0
static UIImage * __nullable _CoreGraphicsScale(PRIVATE_SELF(UIImage),
                                               CGSize scaledDimensions,
                                               CGFloat scale)
{
    CGImageRef cgImage = self.CGImage;
    if (!cgImage) {
        return nil;
    }

    const UIImageOrientation orientation = self.imageOrientation;
    switch (orientation) {
        case UIImageOrientationLeft:
        case UIImageOrientationRight:
        case UIImageOrientationLeftMirrored:
        case UIImageOrientationRightMirrored:
            // swap the dimensions
            scaledDimensions = CGSizeMake(scaledDimensions.height, scaledDimensions.width);
            break;
        default:
            break;
    }

    const size_t bitsPerComponent = 8;
    const CGColorSpaceRef colorSpace = CGImageGetColorSpace(cgImage);
    const uint32_t bitmapInfo = [self tip_hasAlpha:NO] ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast;
    __block UIImage *image = nil;

    TIPExecuteCGContextBlock(^{
        CGContextRef context = CGBitmapContextCreate(NULL /* void * data */,
                                                     (size_t)scaledDimensions.width,
                                                     (size_t)scaledDimensions.height,
                                                     bitsPerComponent,
                                                     0 /* bytesPerRow (auto) */,
                                                     colorSpace,
                                                     bitmapInfo);
        TIPDeferRelease(context);
        if (!context) {
            return;
        }

        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);

        CGRect rect = CGRectZero;
        rect.size = scaledDimensions;
        CGContextDrawImage(context, rect, cgImage);

        CGImageRef scaledCGImage = CGBitmapContextCreateImage(context);
        TIPDeferRelease(scaledCGImage);

        image = [UIImage imageWithCGImage:scaledCGImage
                                    scale:((0.0 == scale) ? [UIScreen mainScreen].scale : scale)
                              orientation:orientation];
    });
    return image;
}
#endif

static UIImage *_UIKitScale(PRIVATE_SELF(UIImage),
                            CGSize scaledDimensions,
                            CGFloat scale)
{
    TIPAssert(self);
    if (0.0 == scale) {
        scale = [UIScreen mainScreen].scale;
    }
    const CGRect drawRect = CGRectMake(0,
                                       0,
                                       scaledDimensions.width / scale,
                                       scaledDimensions.height / scale);

    if (self.images.count > 1) {
        return _UIKitScaleAnimated(self, drawRect, scale);
    }

    UIImage *image = [self tip_imageWithRenderFormatting:^(id<TIPRenderImageFormat> format) {
        format.scale = scale;
        format.renderSize = drawRect.size;
    } render:^(UIImage *sourceImage, CGContextRef ctx) {
        [self drawInRect:drawRect];
    }];
    return image ?: (UIImage * _Nonnull)self;
}

static UIImage *_UIKitScaleAnimated(PRIVATE_SELF(UIImage),
                                    CGRect drawRect,
                                    CGFloat scale)
{
    TIPAssert(self.images.count > 1);
    TIPAssert(scale != 0.);

    const BOOL hasAlpha = ![self tip_hasAlpha:NO];
    __block UIImage *outImage = self;

    TIPExecuteCGContextBlock(^{
        // Modern animation scaling
        if ([UIGraphicsRenderer class] != Nil) {
            UIGraphicsImageRendererFormat *format = self.imageRendererFormat;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:drawRect.size format:format];
            NSMutableArray *newFrames = [[NSMutableArray alloc] initWithCapacity:self.images.count];
            for (UIImage *frame in self.images) {
                @autoreleasepool {
                    UIImage *newFrame = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
                        [frame drawInRect:drawRect];
                    }];
                    if (!newFrame) {
                        // buggy scaling of animation, give up
                        newFrames = nil;
                        break;
                    }
                    [newFrames addObject:newFrame];
                    if (hasAlpha) {
                        CGContextClearRect(UIGraphicsGetCurrentContext(), drawRect);
                    }
                }
            }
            if (newFrames) {
                outImage = [UIImage animatedImageWithImages:newFrames duration:self.duration];
                return;
            }
        }

        // Legacy animation scaling
        {
            UIGraphicsBeginImageContextWithOptions(drawRect.size, !hasAlpha, scale);
            tip_defer(^{
                UIGraphicsEndImageContext();
            });
            NSMutableArray *newFrames = [[NSMutableArray alloc] initWithCapacity:self.images.count];
            for (UIImage *frame in self.images) {
                @autoreleasepool {
                    [frame drawInRect:drawRect];
                    UIImage *newFrame = UIGraphicsGetImageFromCurrentImageContext();
                    if (!newFrame) {
                        return; // buggy scaling, give up
                    }
                    [newFrames addObject:newFrame];
                    if (hasAlpha) {
                        CGContextClearRect(UIGraphicsGetCurrentContext(), drawRect);
                    }
                }
            }
            outImage = [UIImage animatedImageWithImages:newFrames duration:self.duration];
        }
    });

    return outImage;
}

- (UIImage *)tip_scaledImageWithTargetDimensions:(CGSize)targetDimensions
                                     contentMode:(UIViewContentMode)targetContentMode
{
    return [self tip_scaledImageWithTargetDimensions:targetDimensions
                                         contentMode:targetContentMode
                                              decode:YES];
}

- (UIImage *)tip_scaledImageWithTargetDimensions:(CGSize)targetDimensions
                                     contentMode:(UIViewContentMode)targetContentMode
                                          decode:(BOOL)decode
{
    const CGSize dimensions = [self tip_dimensions];
    const CGSize scaledTargetDimensions = TIPSizeGreaterThanZero(targetDimensions) ? TIPDimensionsScaledToTargetSizing(dimensions, targetDimensions, targetContentMode) : CGSizeZero;
    UIImage *image;

    // If we have a target size and the target size is not the same as our source image's size, draw the resized image
    if (TIPSizeGreaterThanZero(scaledTargetDimensions) && !CGSizeEqualToSize(dimensions, scaledTargetDimensions)) {


        // scale with UIKit at screen scale
        image = _UIKitScale(self, scaledTargetDimensions, 0 /*auto scale*/);

        // image = _CoreGraphicsScale(self, scaledTargetDimensions, 0 /*auto scale*/);

    } else {
        image = self;
    }

    // OK, so, to provide some context:
    //
    // The UIKit and CoreGraphics mechanisms for scaling occasionally yield a `nil` image.
    // We cannot repro locally, but externally, it is clearly an issue that affects users.
    // It has noticeably upticked in iOS 11 as well.
    //
    // There are numerous radars out there against this, including #33057552 and #22097047.
    // It has not been fixed in years and we see no reason to expect a fix in the future.
    //
    // Rather than incur complexity of implementing our own custom pixel buffer scaling
    // as a fallback, we'll instead just return `self` unscaled.  This is not ideal,
    // but returning a `nil` image is crash prone while returning the image unscaled
    // would merely be prone to a performance hit.
    if (!image) {
        NSDictionary *userInfo = @{
                                   TIPProblemInfoKeyImageDimensions : [NSValue valueWithCGSize:dimensions],
                                   TIPProblemInfoKeyTargetDimensions : [NSValue valueWithCGSize:targetDimensions],
                                   TIPProblemInfoKeyTargetContentMode : @(targetContentMode),
                                   TIPProblemInfoKeyScaledDimensions : [NSValue valueWithCGSize:scaledTargetDimensions],
                                   TIPProblemInfoKeyImageIsAnimated : @(self.images.count > 1),
                                   @"scale" : @([UIScreen mainScreen].scale),
                                   };
        [[TIPGlobalConfiguration sharedInstance] postProblem:TIPProblemImageFailedToScale userInfo:userInfo];
        image = self; // yuck!
    }
    TIPAssert(image != nil);

    if (decode) {
        [image tip_decode];
    }

    return image;
}

- (UIImage *)tip_orientationAdjustedImage
{
    UIImage *sourceImage = self;

    if (UIImageOrientationUp == sourceImage.imageOrientation) {
        return sourceImage;
    }

    if (sourceImage.CIImage) {
        sourceImage = [sourceImage tip_CGImageBackedImageAndReturnError:NULL] ?: sourceImage;
    }

    if (!sourceImage.CGImage) {
        return sourceImage; // TODO: support rotating animated images
    }

    CGSize dimensions = [sourceImage tip_dimensions];
    CGAffineTransform transform = CGAffineTransformIdentity;

    // 1) rotate
    switch (sourceImage.imageOrientation) {
        case UIImageOrientationDown:
        case UIImageOrientationDownMirrored:
            transform = CGAffineTransformTranslate(transform, dimensions.width, dimensions.height);
            transform = CGAffineTransformRotate(transform, (CGFloat)M_PI);
            break;

        case UIImageOrientationLeft:
        case UIImageOrientationLeftMirrored:
            transform = CGAffineTransformTranslate(transform, dimensions.width, 0);
            transform = CGAffineTransformRotate(transform, (CGFloat)M_PI_2);
            break;

        case UIImageOrientationRight:
        case UIImageOrientationRightMirrored:
            transform = CGAffineTransformTranslate(transform, 0, dimensions.height);
            transform = CGAffineTransformRotate(transform, (CGFloat)-M_PI_2);
            break;
        case UIImageOrientationUp:
            TIPAssertNever();
        case UIImageOrientationUpMirrored:
            break;
    }

    // Flip
    switch (sourceImage.imageOrientation) {
        case UIImageOrientationUpMirrored:
        case UIImageOrientationDownMirrored:
            transform = CGAffineTransformTranslate(transform, dimensions.width, 0);
            transform = CGAffineTransformScale(transform, -1, 1);
            break;

        case UIImageOrientationLeftMirrored:
        case UIImageOrientationRightMirrored:
            transform = CGAffineTransformTranslate(transform, dimensions.height, 0);
            transform = CGAffineTransformScale(transform, -1, 1);
            break;
        case UIImageOrientationUp:
            TIPAssertNever();
        case UIImageOrientationDown:
        case UIImageOrientationLeft:
        case UIImageOrientationRight:
            break;
    }

    // Draw
    __block UIImage *image = nil;
    TIPExecuteCGContextBlock(^{
        CGContextRef ctx = CGBitmapContextCreate(NULL,
                                                 (size_t)dimensions.width,
                                                 (size_t)dimensions.height,
                                                 CGImageGetBitsPerComponent(sourceImage.CGImage),
                                                 0,
                                                 CGImageGetColorSpace(sourceImage.CGImage),
                                                 CGImageGetBitmapInfo(sourceImage.CGImage));
        TIPDeferRelease(ctx);
        CGContextConcatCTM(ctx, transform);
        switch (sourceImage.imageOrientation) {
            case UIImageOrientationLeft:
            case UIImageOrientationLeftMirrored:
            case UIImageOrientationRight:
            case UIImageOrientationRightMirrored:
                CGContextDrawImage(ctx, CGRectMake(0, 0, dimensions.height, dimensions.width), sourceImage.CGImage);
                break;
            default:
                CGContextDrawImage(ctx, CGRectMake(0, 0, dimensions.width, dimensions.height), sourceImage.CGImage);
                break;
        }

        // Get the image
        CGImageRef cgImage = CGBitmapContextCreateImage(ctx);
        TIPDeferRelease(cgImage);
        image = [UIImage imageWithCGImage:cgImage
                                    scale:sourceImage.scale
                              orientation:UIImageOrientationUp];
    });
    return image;
}

- (UIImage *)tip_imageByUpdatingScale:(CGFloat)scale
{
    if (scale == self.scale) {
        return self;
    }

    CGImageRef cgImageRef = self.CGImage;
    if (cgImageRef) {
        return [[UIImage alloc] initWithCGImage:cgImageRef
                                          scale:scale
                                    orientation:self.imageOrientation];
    }

    CGRect imageRect = CGRectZero;
    imageRect.size = TIPDimensionsToSizeScaled(self.tip_dimensions, scale);

    return [self tip_imageWithRenderFormatting:^(id<TIPRenderImageFormat>  _Nonnull format) {
        format.scale = scale;
        format.renderSize = imageRect.size;
    } render:^(UIImage * _Nullable sourceImage, CGContextRef  _Nonnull ctx) {
        [sourceImage drawInRect:imageRect];
    }];
}

- (nullable UIImage *)tip_CGImageBackedImageAndReturnError:(out NSError * __autoreleasing __nullable * __nullable)error
{
    __block NSError *outError = nil;
    tip_defer(^{
        if (error) {
            *error = outError;
        }
    });

    if (self.CGImage) {
        return self;
    }

    if (tip_available_ios_9) {
        // can do GPU work in the background
    } else {
        if (!TIPIsExtension()) {
            // Cannot do GPU work in the background before iOS 9
            Class UIApplicationClass = NSClassFromString(@"UIApplication");
            if ([[UIApplicationClass sharedApplication] applicationState] == UIApplicationStateBackground) {
                // In background, abort
                outError = [NSError errorWithDomain:TIPErrorDomain
                                               code:TIPErrorCodeCannotUseGPUInBackground
                                           userInfo:nil];
                return nil;
            }
        }
    }

    CIImage *CIImage = self.CIImage;
    if (!CIImage) {
        outError = [NSError errorWithDomain:TIPErrorDomain
                                       code:TIPErrorCodeMissingCIImage
                                   userInfo:nil];
        return nil;
    }

    __block UIImage *image = nil;
    TIPExecuteCGContextBlock(^{
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:CIImage fromRect:CIImage.extent];
        TIPDeferRelease(cgImage);
        if (cgImage) {
            image = [UIImage imageWithCGImage:cgImage
                                        scale:self.scale
                                  orientation:self.imageOrientation];
        }
    });

    if (!image) {
        outError = [NSError errorWithDomain:TIPErrorDomain
                                       code:TIPErrorCodeUnknown
                                   userInfo:nil];
        return nil;
    }

    return image;
}

- (nullable UIImage *)tip_grayscaleImage
{
    CGImageRef originalImageRef = self.CGImage;
    CGImageRef grayscaleImageRef = TIPCGImageCreateGrayscale(originalImageRef);
    TIPDeferRelease(grayscaleImageRef);
    if (!grayscaleImageRef) {
        return nil;
    } else if (grayscaleImageRef == originalImageRef) {
        return self;
    }
    return [UIImage imageWithCGImage:grayscaleImageRef];
}

- (nullable UIImage *)tip_blurredImageWithRadius:(CGFloat)blurRadius
{
    return [self tip_imageWithBlurWithRadius:blurRadius
                                   tintColor:nil
                       saturationDeltaFactor:1.0
                                   maskImage:nil];
}

- (nullable UIImage *)tip_imageWithBlurWithRadius:(CGFloat)blurRadius
                                        tintColor:(nullable UIColor *)tintColor
                            saturationDeltaFactor:(CGFloat)saturationDeltaFactor
                                        maskImage:(nullable UIImage *)maskImage
{
    UIImage *image = self;

    const CGSize imageSize = TIPDimensionsToPointSize(image.tip_dimensions);

    // Check pre-conditions
    if (imageSize.width < 1 || imageSize.height < 1) {
        return nil;
    }
    if (!image.CGImage) {
        return nil;
    }
    if (maskImage && !maskImage.CGImage) {
        return nil;
    }

    __block UIImage *outputImage = nil;
    TIPExecuteCGContextBlock(^{
        CGRect imageRect = { CGPointZero, imageSize };
        UIImage *effectImage = image;

        const CGFloat scale = [[UIScreen mainScreen] scale];
        const BOOL hasBlur = blurRadius > __FLT_EPSILON__;
        const BOOL hasSaturationChange = fabs(saturationDeltaFactor - 1.) > __FLT_EPSILON__;
        if (hasBlur || hasSaturationChange) {
            UIGraphicsBeginImageContextWithOptions(imageSize, NO, scale);

            CGContextRef effectInContext = UIGraphicsGetCurrentContext();
            CGContextScaleCTM(effectInContext, 1.0, -1.0);
            CGContextTranslateCTM(effectInContext, 0, -imageSize.height);
            CGContextDrawImage(effectInContext, imageRect, image.CGImage);

            vImage_Buffer effectInBuffer;
            effectInBuffer.data     = CGBitmapContextGetData(effectInContext);
            effectInBuffer.width    = CGBitmapContextGetWidth(effectInContext);
            effectInBuffer.height   = CGBitmapContextGetHeight(effectInContext);
            effectInBuffer.rowBytes = CGBitmapContextGetBytesPerRow(effectInContext);

            UIGraphicsBeginImageContextWithOptions(imageSize, NO, scale);

            CGContextRef effectOutContext = UIGraphicsGetCurrentContext();
            vImage_Buffer effectOutBuffer;
            effectOutBuffer.data     = CGBitmapContextGetData(effectOutContext);
            effectOutBuffer.width    = CGBitmapContextGetWidth(effectOutContext);
            effectOutBuffer.height   = CGBitmapContextGetHeight(effectOutContext);
            effectOutBuffer.rowBytes = CGBitmapContextGetBytesPerRow(effectOutContext);

            if (hasBlur) {
                // A description of how to compute the box kernel width from the Gaussian
                // radius (aka standard deviation) appears in the SVG spec:
                // http://www.w3.org/TR/SVG/filters.html#feGaussianBlurElement
                //
                // For larger values of 's' (s >= 2.0), an approximation can be used: Three
                // successive box-blurs build a piece-wise quadratic convolution kernel, which
                // approximates the Gaussian kernel to within roughly 3%.
                //
                // let d = floor(s * 3*sqrt(2*pi)/4 + 0.5)
                //
                // ... if d is odd, use three box-blurs of size 'd', centered on the output pixel.
                //
                const CGFloat inputRadius = blurRadius;
                uint32_t radius = (uint32_t)floor(inputRadius * 3. * sqrt(2 * M_PI) / 4 + 0.5);
                if (radius % 2 != 1) {
                    radius += 1; // force radius to be odd so that the three box-blur methodology works.
                }
                vImageBoxConvolve_ARGB8888(&effectInBuffer, &effectOutBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
                vImageBoxConvolve_ARGB8888(&effectOutBuffer, &effectInBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
                vImageBoxConvolve_ARGB8888(&effectInBuffer, &effectOutBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
            }

            const BOOL swapEffectImageBuffer = (hasSaturationChange && hasBlur);
            if (hasSaturationChange) {
                const CGFloat s = saturationDeltaFactor;
                const CGFloat floatingPointSaturationMatrix[] = {
                    0.0722f + (0.9278f * s),  0.0722f - (0.0722f * s),  0.0722f - (0.0722f * s),  0,
                    0.7152f - (0.7152f * s),  0.7152f + (0.2848f * s),  0.7152f - (0.7152f * s),  0,
                    0.2126f - (0.2126f * s),  0.2126f - (0.2126f * s),  0.2126f + (0.7873f * s),  0,
                                          0,                        0,                        0,  1,
                };
                const int32_t divisor = 256;
                const NSUInteger matrixSize = sizeof(floatingPointSaturationMatrix)/sizeof(floatingPointSaturationMatrix[0]);
                int16_t saturationMatrix[matrixSize];
                for (NSUInteger i = 0; i < matrixSize; ++i) {
#if CGFLOAT_IS_DOUBLE
                    saturationMatrix[i] = (int16_t)round(floatingPointSaturationMatrix[i] * divisor);
#else
                    saturationMatrix[i] = (int16_t)roundf(floatingPointSaturationMatrix[i] * divisor);
#endif
                }
                if (swapEffectImageBuffer) {
                    vImageMatrixMultiply_ARGB8888(&effectOutBuffer, &effectInBuffer, saturationMatrix, divisor, NULL, NULL, kvImageNoFlags);
                }else {
                    vImageMatrixMultiply_ARGB8888(&effectInBuffer, &effectOutBuffer, saturationMatrix, divisor, NULL, NULL, kvImageNoFlags);
                }
            }

            if (!swapEffectImageBuffer) {
                effectImage = UIGraphicsGetImageFromCurrentImageContext();
            }
            UIGraphicsEndImageContext();

            if (swapEffectImageBuffer) {
                effectImage = UIGraphicsGetImageFromCurrentImageContext();
            }
            UIGraphicsEndImageContext();
        }

        // Set up output context.
        UIGraphicsBeginImageContextWithOptions(imageSize, NO, scale);
        tip_defer(^{
            UIGraphicsEndImageContext();
        });

        CGContextRef outputContext = UIGraphicsGetCurrentContext();
        CGContextScaleCTM(outputContext, 1.0, -1.0);
        CGContextTranslateCTM(outputContext, 0, -imageSize.height);

        // Draw base image.
        CGContextDrawImage(outputContext, imageRect, image.CGImage);

        // Draw effect image.
        if (hasBlur || hasSaturationChange || maskImage) {
            CGContextSaveGState(outputContext);
            if (maskImage) {
                CGContextClipToMask(outputContext, imageRect, maskImage.CGImage);
            }
            CGContextDrawImage(outputContext, imageRect, effectImage.CGImage);
            CGContextRestoreGState(outputContext);
        }

        // Add tint color
        if (tintColor) {
            CGContextSaveGState(outputContext);
            CGContextSetFillColorWithColor(outputContext, tintColor.CGColor);
            CGContextFillRect(outputContext, imageRect);
            CGContextRestoreGState(outputContext);
        }

        // Output image is ready.
        outputImage = UIGraphicsGetImageFromCurrentImageContext();
    });

    return outputImage;
}

#pragma mark Decode Methods

+ (nullable UIImage *)tip_thumbnailImageWithFileURL:(NSURL *)fileURL
                          thumbnailMaximumDimension:(CGFloat)thumbnailMaximumDimension
{
    if (!fileURL.isFileURL) {
        return nil;
    }

    NSDictionary *options = @{
                              (id)kCGImageSourceShouldCache : (id)kCFBooleanFalse,
                              (id)kCGImageSourceThumbnailMaxPixelSize : @(thumbnailMaximumDimension),
                              (id)kCGImageSourceCreateThumbnailFromImageAlways : (id)kCFBooleanTrue,
                              (id)kCGImageSourceShouldAllowFloat : (id)kCFBooleanTrue,
                              (id)kCGImageSourceCreateThumbnailWithTransform : (id)kCFBooleanTrue,
                              };
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((CFURLRef)fileURL, (CFDictionaryRef)options);
    if (!imageSource) {
        return nil;
    }

    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, (CFDictionaryRef)options);
    CFRelease(imageSource);
    if (!imageRef) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:imageRef scale:(CGFloat)1.f orientation:UIImageOrientationUp];
    CFRelease(imageRef);
    return image;
}

+ (nullable UIImage *)tip_imageWithAnimatedImageFile:(NSString *)filePath
                                           durations:(out NSArray<NSNumber *> * __autoreleasing __nullable * __nullable)durationsOut
                                           loopCount:(out NSUInteger * __nullable)loopCountOut
{
    NSURL *fileURL = [NSURL fileURLWithPath:filePath isDirectory:NO];
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((CFURLRef)fileURL, NULL);
    TIPDeferRelease(imageSource);
    if (imageSource) {
        return [self tip_imageWithAnimatedImageSource:imageSource
                                            durations:durationsOut
                                            loopCount:loopCountOut];
    }
    return nil;
}

+ (nullable UIImage *)tip_imageWithAnimatedImageData:(NSData *)data
                                           durations:(out NSArray<NSNumber *> * __autoreleasing __nullable * __nullable)durationsOut
                                           loopCount:(out NSUInteger * __nullable)loopCountOut
{
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    TIPDeferRelease(imageSource);
    if (imageSource) {
        return [self tip_imageWithAnimatedImageSource:imageSource
                                            durations:durationsOut
                                            loopCount:loopCountOut];
    }
    return nil;
}

#pragma mark Encode Methods

- (BOOL)tip_writeToCGImageDestinationWithBlock:(CGImageDestinationRef(^)(NSString *UTType, const NSUInteger imageCount))desinationCreationBlock
                                          type:(nullable NSString *)type
                               encodingOptions:(TIPImageEncodingOptions)options
                                       quality:(float)quality
                            animationLoopCount:(NSUInteger)animationLoopCount
                       animationFrameDurations:(nullable NSArray<NSNumber *> *)animationFrameDurations
                                         error:(out NSError * __autoreleasing __nullable * __nullable)error
{
    __block NSError *theError = nil;
    tip_defer(^{
        if (error) {
            *error = theError;
        }
    });

    UIImage *image = self;
    if (image.CIImage && !image.CGImage && image.images.count == 0) {
        image = [image tip_CGImageBackedImageAndReturnError:&theError];
        if (theError != nil) {
            return NO;
        }
        TIPAssert(image != nil);
    }

    if (!image.CGImage && image.images.count == 0) {
        theError = [NSError errorWithDomain:TIPErrorDomain code:TIPErrorCodeMissingCGImage userInfo:nil];
        return NO;
    }

    if (!type) {
        const TIPRecommendedImageTypeOptions recoOptions = TIPRecommendedImageTypeOptionsFromEncodingOptions(options, quality);
        type = [self tip_recommendedImageType:recoOptions];
    }

    TIPAssert(type != nil);
    NSString *typeString = TIPImageTypeToUTType(type);
    if (!typeString || !TIPImageTypeCanWriteWithImageIO(type)){
        theError = [NSError errorWithDomain:TIPErrorDomain code:TIPErrorCodeEncodingUnsupported userInfo:(type) ? @{ @"imageType" : type } : nil];
        return NO;
    }

    // Write
    const NSUInteger imageCount = [image tip_imageCountBasedOnImageType:type];
    CGImageDestinationRef destinationRef = desinationCreationBlock(typeString, imageCount);
    TIPDeferRelease(destinationRef);
    if (destinationRef) {
        const BOOL success = [image tip_writeToCGImageDestination:destinationRef
                                                             type:type
                                                  encodingOptions:options
                                                          quality:quality
                                               animationLoopCount:animationLoopCount
                                          animationFrameDurations:animationFrameDurations
                                                            error:&theError];

        if (!success) {
            TIPAssert(theError != nil);
            return NO;
        }
    } else {
        theError = [NSError errorWithDomain:TIPErrorDomain code:TIPErrorCodeFailedToInitializeImageDestination userInfo:nil];
        return NO;
    }

    return YES;
}

- (nullable NSData *)tip_writeToDataWithType:(nullable NSString *)type
                             encodingOptions:(TIPImageEncodingOptions)options
                                     quality:(float)quality
                          animationLoopCount:(NSUInteger)animationLoopCount
                     animationFrameDurations:(nullable NSArray<NSNumber *> *)animationFrameDurations
                                       error:(out NSError * __autoreleasing __nullable * __nullable)error
{
    __block NSError *theError = nil;
    tip_defer(^{
        if (error) {
            *error = theError;
        }
    });

    NSMutableData *mData = [[NSMutableData alloc] init];
    CGImageDestinationRef (^destinationBlock)(NSString *, const NSUInteger) = ^CGImageDestinationRef(NSString *UTType, const NSUInteger imageCount) {
        return CGImageDestinationCreateWithData((__bridge CFMutableDataRef)mData, (__bridge CFStringRef)UTType, imageCount, NULL);
    };
    const BOOL success = [self tip_writeToCGImageDestinationWithBlock:destinationBlock
                                                                 type:type
                                                      encodingOptions:options
                                                              quality:quality
                                                   animationLoopCount:animationLoopCount
                                              animationFrameDurations:animationFrameDurations
                                                                error:&theError];
    TIPAssert(!!success ^ !!theError);
    return success ? mData : nil;
}

- (BOOL)tip_writeToFile:(NSString *)filePath
                   type:(nullable NSString *)type
        encodingOptions:(TIPImageEncodingOptions)options
                quality:(float)quality
     animationLoopCount:(NSUInteger)animationLoopCount
animationFrameDurations:(nullable NSArray<NSNumber *> *)animationFrameDurations
             atomically:(BOOL)atomic
                  error:(out NSError * __autoreleasing __nullable * __nullable)error
{
    TIPAssert(filePath != nil);

    __block NSError *theError = nil;
    tip_defer(^{
        if (error) {
            *error = theError;
        }
    });

    if (!filePath) {
        theError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }

    NSURL *finalFilePathURL = [NSURL fileURLWithPath:filePath isDirectory:NO];
    NSURL *writeFilePathURL = atomic ? [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:NO] : finalFilePathURL;
    if (finalFilePathURL && writeFilePathURL) {
        // Ensure dirs
        [[NSFileManager defaultManager] createDirectoryAtURL:finalFilePathURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        if (atomic) {
            [[NSFileManager defaultManager] createDirectoryAtURL:writeFilePathURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        }
    }

    CGImageDestinationRef (^destinationBlock)(NSString *, const NSUInteger) = ^CGImageDestinationRef(NSString *UTType, const NSUInteger imageCount) {
        return CGImageDestinationCreateWithURL((__bridge CFURLRef)writeFilePathURL, (__bridge CFStringRef)UTType, imageCount, NULL);
    };
    const BOOL success = [self tip_writeToCGImageDestinationWithBlock:destinationBlock
                                                                 type:type
                                                      encodingOptions:options
                                                              quality:quality
                                                   animationLoopCount:animationLoopCount
                                              animationFrameDurations:animationFrameDurations
                                                                error:&theError];
    TIPAssert(!!success ^ !!theError);
    if (success) {
        if (atomic) {
            // Atomic move
            if (![[NSFileManager defaultManager] moveItemAtURL:writeFilePathURL toURL:finalFilePathURL error:&theError]) {
                TIPAssert(theError != nil);
                return NO;
            }
        }
    }

    return success;
}

#pragma mark Other Methods

- (void)tip_decode
{
    // Animated images cannot be "decoded".
    // Decoding an animated image (sourced from a GIF) appears to crash 100% on iOS 10.
    // Crashes on iOS 8 and 9 too, but very infrequently.
    // We'll avoid it altogether to be safe.
    if (self.images.count <= 0) {
        (void)[self tip_imageWithRenderFormatting:^(id<TIPRenderImageFormat> format) {
            format.renderSize = CGSizeMake(1, 1);
        } render:^(UIImage *sourceImage, CGContextRef ctx) {
            [sourceImage drawAtPoint:CGPointZero];
        }];
    }
}

@end

@implementation UIImage (TIPAdditions_CGImage)

- (BOOL)tip_writeToCGImageDestination:(CGImageDestinationRef)destinationRef
                                 type:(nullable NSString *)type
                      encodingOptions:(TIPImageEncodingOptions)options
                              quality:(float)quality
                   animationLoopCount:(NSUInteger)animationLoopCount
              animationFrameDurations:(nullable NSArray<NSNumber *> *)animationFrameDurations
                                error:(out NSError * __autoreleasing __nullable * __nullable)error
{
    __block NSError *theError = nil;
    tip_defer(^{
        if (error) {
            *error = theError;
        }
    });

    if (!type) {
        const TIPRecommendedImageTypeOptions recoOptions = TIPRecommendedImageTypeOptionsFromEncodingOptions(options, quality);
        type = [self tip_recommendedImageType:recoOptions];
    }

    const NSUInteger count = [self tip_imageCountBasedOnImageType:type];
    if (count > 1) {
        // Animated!

        // Prep to see if we have duration overrides in our meta data
        if (animationFrameDurations.count != count) {
            animationFrameDurations = nil;
        }

        NSDictionary *properties = TIPImageWritingProperties(self,
                                                             type,
                                                             options,
                                                             quality,
                                                             @(animationLoopCount),
                                                             nil,
                                                             YES);
        CGImageDestinationSetProperties(destinationRef, (__bridge CFDictionaryRef)properties);

        for (NSUInteger i = 0; i < count; i++) {
            UIImage *subimage = self.images[i];
            if (!subimage.CGImage) {
                theError = [NSError errorWithDomain:TIPErrorDomain code:TIPErrorCodeMissingCGImage userInfo:nil];
                break;
            }

            properties = TIPImageWritingProperties(self,
                                                   type,
                                                   options,
                                                   quality,
                                                   @(animationLoopCount),
                                                   animationFrameDurations ? animationFrameDurations[i] : nil,
                                                   NO);
            CGImageDestinationAddImage(destinationRef, subimage.CGImage, (__bridge CFDictionaryRef)properties);
        }
    } else {
        // Not animated

        const BOOL grayscale = TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPImageEncodingGrayscale);
        CGImageRef cgImage = self.CGImage ?: [self.images.firstObject CGImage];
        if (grayscale) {
            cgImage = TIPCGImageCreateGrayscale(cgImage);
        }

        if (cgImage) {
            NSDictionary *properties = TIPImageWritingProperties(self, type, options, quality, nil, nil, NO);
            CGImageDestinationAddImage(destinationRef, cgImage, (__bridge CFDictionaryRef)properties);
            if (grayscale) {
                CFRelease(cgImage);
            }
        } else {
            theError = [NSError errorWithDomain:TIPErrorDomain code:TIPErrorCodeMissingCGImage userInfo:nil];
        }
    }

    if (!theError && !CGImageDestinationFinalize(destinationRef)) {
        theError = [NSError errorWithDomain:TIPErrorDomain code:TIPErrorCodeFailedToFinalizeImageDestination userInfo:nil];
    }

    return !theError;
}

+ (nullable UIImage *)tip_imageWithAnimatedImageSource:(CGImageSourceRef)source
                                             durations:(out NSArray<NSNumber *> * __autoreleasing __nullable * __nullable)durationsOut
                                             loopCount:(out NSUInteger * __nullable)loopCountOut
{
    UIImage *image = nil;
    NSTimeInterval duration = 0.0;
    size_t const count = CGImageSourceGetCount(source);
    if (count > 1 && loopCountOut) {
        CFDictionaryRef topLevelProperties = CGImageSourceCopyProperties(source, NULL);
        TIPDeferRelease(topLevelProperties);

        if (topLevelProperties) {
            NSNumber *loopCount = nil;
            CFDictionaryRef topLevelGIFProperties = CFDictionaryGetValue(topLevelProperties, kCGImagePropertyGIFDictionary);
            if (topLevelGIFProperties) {
                loopCount = (NSNumber *)CFDictionaryGetValue(topLevelGIFProperties, kCGImagePropertyGIFLoopCount);
            } else {
                CFDictionaryRef topLevelPNGProperties = CFDictionaryGetValue(topLevelProperties, kCGImagePropertyPNGDictionary);
                if (topLevelPNGProperties) {
                    loopCount = (NSNumber *)CFDictionaryGetValue(topLevelPNGProperties, kCGImagePropertyAPNGLoopCount);
                }
            }
            *loopCountOut = (loopCount) ? loopCount.unsignedIntegerValue : 0;
        } else {
            *loopCountOut = 0;
        }
    }

    const CGFloat scale = [UIScreen mainScreen].scale;
    NSMutableArray *durations = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *images = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
        TIPDeferRelease(properties);
        if (properties) {
            const CGImagePropertyOrientation cgOrientation = [[(__bridge NSDictionary *)properties objectForKey:(NSString *)kCGImagePropertyOrientation] unsignedIntValue];
            const UIImageOrientation orientation = TIPUIImageOrientationFromCGImageOrientation(cgOrientation);
            CGImageRef imageRef = CGImageSourceCreateImageAtIndex(source, i, NULL);
            TIPDeferRelease(imageRef);
            if (imageRef) {
                UIImage *frame = [UIImage imageWithCGImage:imageRef scale:scale orientation:orientation];
                if (frame) {
                    float additionalDuration = 0.0;

                    CFStringRef unclampedDelayTimeKey = NULL;
                    CFStringRef delayTimeKey = NULL;
                    CFDictionaryRef animatedProperties = NULL;

                    animatedProperties = CFDictionaryGetValue(properties, kCGImagePropertyGIFDictionary);
                    if (animatedProperties) {
                        // GIF
                        unclampedDelayTimeKey = kCGImagePropertyGIFUnclampedDelayTime;
                        delayTimeKey = kCGImagePropertyGIFDelayTime;
                    } else {
                        animatedProperties = CFDictionaryGetValue(properties, kCGImagePropertyPNGDictionary);
                        if (animatedProperties) {
                            // APNG
                            unclampedDelayTimeKey = kCGImagePropertyAPNGUnclampedDelayTime;
                            delayTimeKey = kCGImagePropertyAPNGDelayTime;
                        }
                    }

                    if (animatedProperties) {

                        NSNumber *unclampedDelayTime = (NSNumber *)CFDictionaryGetValue(animatedProperties, unclampedDelayTimeKey);
                        if (unclampedDelayTime) {
                            additionalDuration = unclampedDelayTime.floatValue;
                        } else {
                            NSNumber *delayTime = (NSNumber *)CFDictionaryGetValue(animatedProperties, delayTimeKey);
                            if (delayTime) {
                                additionalDuration = delayTime.floatValue;
                            }
                        }

                    } else {
                        TIPLogWarning(@"No GIF/PNG dictionary in properties for animated image : %@", (__bridge NSDictionary *)properties);
                    }

                    if (additionalDuration < 0.01f + FLT_EPSILON) {
                        additionalDuration = 0.1f;
                    }
                    duration += additionalDuration;

                    [images addObject:frame];
                    [durations addObject:@(additionalDuration)];
                }
            }
        }
    }

    if (images.count > 0) {
        if (images.count == 1) {
            image = images.firstObject;
        } else {
            image = [UIImage animatedImageWithImages:images duration:duration];
        }
    }

    if (durationsOut) {
        *durationsOut = [durations copy];
    }

    return image;
}

@end

static NSDictionary *TIPImageWritingProperties(UIImage *image,
                                               NSString *type,
                                               TIPImageEncodingOptions options,
                                               float quality,
                                               NSNumber * __nullable animationLoopCount,
                                               NSNumber * __nullable animationDuration,
                                               BOOL isGlobalProperties)
{
    const BOOL preferProgressive = TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPImageEncodingProgressive);
    const BOOL isAnimated = image.images.count > 1;
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];

    // TODO: investigate if we should be using kCGImageDestinationOptimizeColorForSharing
    /*
     if (&kCGImageDestinationOptimizeColorForSharing != NULL) {
        properties[(NSString *)kCGImageDestinationOptimizeColorForSharing] = (__bridge id)kCFBooleanTrue;
     }
     */

    properties[(NSString *)kCGImagePropertyOrientation] = @(TIPCGImageOrientationFromUIImageOrientation(image.imageOrientation));

    if (TIPImageTypeSupportsLossyQuality(type)) {
        properties[(NSString *)kCGImageDestinationLossyCompressionQuality] = @(quality);
    }
    if (TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPImageEncodingNoAlpha)) {
        properties[(NSString *)kCGImagePropertyHasAlpha] = (__bridge id)kCFBooleanFalse;
    }
    if (TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPImageEncodingGrayscale)) {
        properties[(NSString *)kCGImagePropertyColorModel] = @"Gray";
    }

    if ([type isEqualToString:TIPImageTypeJPEG]) {
        NSDictionary *jfifInfo = @{
                                   (NSString *)kCGImagePropertyJFIFIsProgressive : (__bridge NSNumber *)((preferProgressive) ? kCFBooleanTrue : kCFBooleanFalse),
                                   (NSString *)kCGImagePropertyJFIFXDensity : @72,
                                   (NSString *)kCGImagePropertyJFIFYDensity : @72,
                                   (NSString *)kCGImagePropertyJFIFDensityUnit : @1,
                                   };
        properties[(NSString *)kCGImagePropertyJFIFDictionary] = jfifInfo;
    } else if ([type isEqualToString:TIPImageTypeJPEG2000]) {
        // TODO: add support for preferProgressive
    } else if ([type isEqualToString:TIPImageTypeTIFF]) {
        NSDictionary *tiffInfo = @{
                                   (NSString *)kCGImagePropertyTIFFCompression : @(/*NSTIFFCompressionLZW*/ 5)
                                   };
        properties[(NSString *)kCGImagePropertyTIFFDictionary] = tiffInfo;
    } else if ([type isEqualToString:TIPImageTypePNG] && !isAnimated) {
        if (preferProgressive) {
            NSDictionary *pngInfo = @{
                                      (NSString *)kCGImagePropertyPNGInterlaceType : @1 // 1 == Adam7 interlaced encoding
                                      };
            properties[(NSString *)kCGImagePropertyPNGDictionary] = pngInfo;
        }
    } else if (isAnimated) {

        NSString *animatedDictionaryKey = nil;
        NSString *animatedValueKey = nil; // loop-count for global, delay-time for image

        if ([type isEqualToString:TIPImageTypeGIF]) {
            animatedDictionaryKey = (NSString *)kCGImagePropertyGIFDictionary;
            animatedValueKey = (isGlobalProperties) ? (NSString *)kCGImagePropertyGIFLoopCount : (NSString *)kCGImagePropertyGIFDelayTime;
        } else if ([type isEqualToString:TIPImageTypePNG]) {
            animatedDictionaryKey = (NSString *)kCGImagePropertyPNGDictionary;
            animatedValueKey = (isGlobalProperties) ? (NSString *)kCGImagePropertyAPNGLoopCount : (NSString *)kCGImagePropertyAPNGDelayTime;
        }

        if (animatedDictionaryKey && animatedValueKey) {
            NSDictionary *animatedDictionary = nil;
            if (isGlobalProperties) {

                const NSUInteger loopCount = animationLoopCount.unsignedIntegerValue;

                // Exceedingly large values have been know to prevent looping from happening at all on browsers.
                // Restrict our loop count here to something that is more than long enough.
                const UInt16 loopCount16 = (UInt16)MIN(loopCount, (NSUInteger)INT16_MAX);

                animatedDictionary = @{ animatedValueKey : @(loopCount16) };

            } else {

                animatedDictionary = @{ animatedValueKey : animationDuration ?: @((float)(image.duration / image.images.count)) };

            }

            properties[animatedDictionaryKey] = animatedDictionary;
        }
    }

    return properties;
}

static CGImageRef __nullable TIPCGImageCreateGrayscale(CGImageRef __nullable imageRef)
{
    if (!imageRef) {
        return NULL;
    }

    CGColorSpaceRef originalColorSpace = CGImageGetColorSpace(imageRef);
    const CGColorSpaceModel model = CGColorSpaceGetModel(originalColorSpace);
    if (model == kCGColorSpaceModelMonochrome) {
        CFRetain(imageRef);
        return imageRef;
    } else if (model == kCGColorSpaceModelRGB || model == kCGColorSpaceModelCMYK) {
        if (1 == CGColorSpaceGetNumberOfComponents(originalColorSpace)) {
            // one component == grayscale
            CFRetain(imageRef);
            return imageRef;
        }
    }

    // Create image rectangle with current image width/height
    CGRect imageRect = CGRectMake(0, 0, CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));

    // Grayscale color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    TIPDeferRelease(colorSpace);

    // Create bitmap content with current image size and grayscale colorspace
    CGContextRef context = CGBitmapContextCreate(nil, (size_t)imageRect.size.width, (size_t)imageRect.size.height, 8, 0, colorSpace, kCGImageAlphaNone);
    TIPDeferRelease(context);

    // Draw image into current context, with specified rectangle
    // using previously defined context (with grayscale colorspace)
    CGContextDrawImage(context, imageRect, imageRef);

    // Create bitmap image info from pixel data in current context
    return CGBitmapContextCreateImage(context);
}

NS_ASSUME_NONNULL_END
