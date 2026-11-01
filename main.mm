#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <string>
#include <fstream>
#include <mutex>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>

enum {
    TagSection = 700,
    TagRow = 701,
    TagTitle = 702,
    TagDetail = 703,
    TagValue = 888,
    TagSlider = 704
};

struct AllModState {
    bool autoSkill = false;
    bool instantSkill = false;
    bool autoAttack = false;
    bool oneHitKill = false;
    bool godMode = false;
    bool defenseBoost = false;
    bool critMultiplier = false;
    bool mapHack = false;
    float speedMultiplier = 1.0f;
    float damageMultiplier = 1.0f;
    float hpMultiplier = 1.0f;
    float attackSpeedMultiplier = 1.0f;
};

static AllModState g_AllState;
static std::ofstream g_LogStream;
static std::mutex g_LogMutex;
static std::mutex g_StateMutex;
static uintptr_t g_UnityFrameworkBase = 0;

#define RVA_UDP_SKILL      0x1743c2c // UdpClient::SendPlayerSkill_C
#define RVA_UDP_SPEED      0x1743d48 // UdpClient::SendPlayerSpeed_C
#define RVA_UDP_DAMAGE     0x1744888 // UdpClient::SendPlayerDamage_C
#define RVA_UDP_DEFENSE    0x1747348 // UdpClient::SendPlayerDefence_C
#define RVA_UDP_ATTACK     0x1747508 // UdpClient::SendPlayerAttack_C
#define RVA_UDP_DEAD       0x1748fbc // UdpClient::SendPlayerDead_C
#define RVA_ENTITY_SPEED   0x19ce918 // EntityAIPlayer::SetfSpeed
#define RVA_TCP_ATTACK     0x407d87c // TcpGame::SendPlayerAttack
#define RVA_TCP_MOVE       0x4089150 // TcpGame::SendPlayerMove_C

void InitAllLogger() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] > 0) {
        NSString *path = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"sheepct_all_features.log"];
        const char *cPath = [path UTF8String];
        if (cPath) {
            std::lock_guard<std::mutex> lock(g_LogMutex);
            g_LogStream.open(cPath, std::ios::out | std::ios::app);
        }
    }
}

void LogAllMessage(const std::string& msg) {
    std::lock_guard<std::mutex> lock(g_LogMutex);
    if (g_LogStream.is_open()) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *dt = [fmt stringFromDate:[NSDate date]];
        const char *dtStr = [dt UTF8String];
        if (dtStr) {
            g_LogStream << "[" << dtStr << "] " << msg << std::endl;
            g_LogStream.flush();
        }
    }
}

uintptr_t ResolveUnityFrameworkBase() {
    if (g_UnityFrameworkBase != 0) return g_UnityFrameworkBase;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "UnityFramework") || strstr(name, "GhostSoulM"))) {
            g_UnityFrameworkBase = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    return g_UnityFrameworkBase;
}

template <typename T, typename... Args>
T CallGameFunction(uintptr_t rva, Args... args) {
    uintptr_t base = ResolveUnityFrameworkBase();
    if (base == 0) return T();
    uintptr_t targetAddr = base + rva;
    
    Dl_info info;
    if (dladdr((void*)targetAddr, &info) == 0) return T();

    T (*func)(Args...) = (T (*)(Args...))targetAddr;
    return func(args...);
}

@interface PassThroughWindow : UIWindow
@end

@implementation PassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}
@end

@interface AllFeatureMenuController : UIViewController
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UILabel *speedLbl, *dmgLbl, *hpLbl, *atkSpdLbl;
@property (nonatomic, assign) BOOL isOpen;
@property (nonatomic, assign) BOOL didDrag;
@property (nonatomic, assign) CGPoint dragStartCenter;
@end

@implementation AllFeatureMenuController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = YES;
    
    [self buildPanel];
    [self buildFloatingButton];
}

- (void)buildFloatingButton {
    self.floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatButton.frame = CGRectMake(18, 120, 58, 58);
    self.floatButton.backgroundColor = [UIColor colorWithRed:0.15 green:0.40 blue:0.90 alpha:0.96];
    [self.floatButton setTitle:@"ALL" forState:UIControlStateNormal];
    [self.floatButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.floatButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    self.floatButton.layer.cornerRadius = 29;
    self.floatButton.layer.borderWidth = 2;
    self.floatButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.8].CGColor;
    self.floatButton.exclusiveTouch = YES;
    
    [self.floatButton addTarget:self action:@selector(floatTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.floatButton addTarget:self action:@selector(floatTouchDown:) forControlEvents:UIControlEventTouchDown];
    [self.floatButton addTarget:self action:@selector(floatDragged:withEvent:) forControlEvents:UIControlEventTouchDragInside | UIControlEventTouchDragOutside];
    [self.floatButton addTarget:self action:@selector(floatTouchEnded:) forControlEvents:UIControlEventTouchUpInside];
    [self.floatButton addTarget:self action:@selector(floatTouchEnded:) forControlEvents:UIControlEventTouchUpOutside];
    [self.floatButton addTarget:self action:@selector(floatTouchEnded:) forControlEvents:UIControlEventTouchCancel];
    
    [self.view addSubview:self.floatButton];
}

- (void)floatTouchDown:(UIButton *)button {
    self.didDrag = NO;
    self.dragStartCenter = button.center;
}

- (void)floatDragged:(UIButton *)button withEvent:(UIEvent *)event {
    UITouch *touch = event.allTouches.anyObject;
    if (!touch) return;

    CGPoint point = [touch locationInView:self.view];
    CGPoint start = [touch previousLocationInView:self.view];

    if (hypot(point.x - self.dragStartCenter.x, point.y - self.dragStartCenter.y) > 6.0) {
        self.didDrag = YES;
    }
    if (!self.didDrag) return;

    CGPoint delta = CGPointMake(point.x - start.x, point.y - start.y);
    CGPoint center = CGPointMake(button.center.x + delta.x, button.center.y + delta.y);

    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        insets = self.view.safeAreaInsets;
    }
    
    CGFloat halfW = CGRectGetWidth(button.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(button.bounds) / 2.0;

    center.x = MAX(insets.left + halfW, MIN(CGRectGetWidth(self.view.bounds) - insets.right - halfW, center.x));
    center.y = MAX(insets.top + halfH, MIN(CGRectGetHeight(self.view.bounds) - insets.bottom - halfH, center.y));

    button.center = center;
}

- (void)floatTouchEnded:(UIButton *)button {
    if (self.didDrag) {
        [button removeTarget:self action:@selector(floatTapped:) forControlEvents:UIControlEventTouchUpInside];
        dispatch_async(dispatch_get_main_queue(), ^{
            [button addTarget:self action:@selector(floatTapped:) forControlEvents:UIControlEventTouchUpInside];
        });
    }
}

- (void)floatTapped:(UIButton *)button {
    if (!self.didDrag) {
        [self toggleMenu];
    }
}

- (void)buildPanel {
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(14, 80, 300, 400)];
    self.panel.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.12 alpha:0.98];
    self.panel.layer.cornerRadius = 18;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithRed:0.35 green:0.45 blue:0.65 alpha:0.9].CGColor;
    self.panel.hidden = YES;
    self.panel.clipsToBounds = YES;
    [self.view addSubview:self.panel];

    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 64)];
    self.headerView.backgroundColor = [UIColor colorWithRed:0.11 green:0.16 blue:0.25 alpha:1];
    [self.panel addSubview:self.headerView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 240, 22)];
    title.tag = TagTitle;
    title.text = @"SHEEPCT  •  ALL FEATURES ENGINE";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [self.headerView addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, 240, 18)];
    sub.tag = TagDetail;
    sub.text = @"Trần Mạnh Cường - Tagged Layout Engine";
    sub.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    sub.font = [UIFont systemFontOfSize:10];
    [self.headerView addSubview:sub];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.tag = 999;
    closeBtn.frame = CGRectMake(300 - 44, 14, 36, 36);
    closeBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    closeBtn.layer.cornerRadius = 18;
    [closeBtn setTitle:@"×" forState:UIControlStateNormal];
    [closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:closeBtn];

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 64, 300, 400 - 64)];
    [self.panel addSubview:self.scrollView];

    AllModState stateCopy;
    {
        std::lock_guard<std::mutex> lock(g_StateMutex);
        stateCopy = g_AllState;
    }

    CGFloat y = 10;
    y = [self addSectionHeader:@"1. Kỹ Năng & Tấn Công" y:y];
    y = [self addSwitchWithTitle:@"Tự động Kỹ năng" detail:@"UdpClient::SendPlayerSkill_C" key:@"autoSkill" y:y on:stateCopy.autoSkill];
    y = [self addSwitchWithTitle:@"Không Hồi Chiêu" detail:@"Instant Cooldown" key:@"instantSkill" y:y on:stateCopy.instantSkill];
    y = [self addSwitchWithTitle:@"Tấn công tốc độ cao" detail:@"TcpGame::SendPlayerAttack" key:@"autoAttack" y:y on:stateCopy.autoAttack];
    y = [self addSwitchWithTitle:@"Một đòn kết liễu" detail:@"One Hit Kill" key:@"oneHit" y:y on:stateCopy.oneHitKill];

    y = [self addSectionHeader:@"2. Phòng Thủ & Sinh Lực" y:y];
    y = [self addSwitchWithTitle:@"Bất tử / Khóa Máu" detail:@"UdpClient::SendPlayerDead_C" key:@"godMode" y:y on:stateCopy.godMode];
    y = [self addSwitchWithTitle:@"Tăng cường Phòng thủ" detail:@"UdpClient::SendPlayerDefence_C" key:@"defense" y:y on:stateCopy.defenseBoost];
    y = [self addSwitchWithTitle:@"Tăng tỷ lệ Chí mạng" detail:@"Crit Rate Boost" key:@"crit" y:y on:stateCopy.critMultiplier];

    y = [self addSectionHeader:@"3. Tốc Độ & Di Chuyển" y:y];
    y = [self addSwitchWithTitle:@"Bản đồ mở rộng (Map Hack)" detail:@"TcpGame::SendPlayerMove_C" key:@"mapHack" y:y on:stateCopy.mapHack];
    
    y = [self addSliderWithTitle:@"Hệ số Tốc độ (Speed Multiplier)" key:101 min:1.0 max:10.0 val:stateCopy.speedMultiplier y:y labelRef:&_speedLbl];
    y = [self addSliderWithTitle:@"Hệ số Sát thương (Damage Multiplier)" key:102 min:1.0 max:20.0 val:stateCopy.damageMultiplier y:y labelRef:&_dmgLbl];
    y = [self addSliderWithTitle:@"Hệ số Máu / HP Multiplier" key:103 min:1.0 max:10.0 val:stateCopy.hpMultiplier y:y labelRef:&_hpLbl];
    y = [self addSliderWithTitle:@"Hệ số Tốc độ Đánh (Attack Speed)" key:104 min:1.0 max:5.0 val:stateCopy.attackSpeedMultiplier y:y labelRef:&_atkSpdLbl];

    self.scrollView.contentSize = CGSizeMake(300, y + 20);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    CGRect safeArea = self.view.bounds;
    if (@available(iOS 11.0, *)) {
        safeArea = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    }
    
    CGFloat maxW = safeArea.size.width;
    CGFloat maxH = safeArea.size.height;
    if (maxW <= 0 || maxH <= 0) return;

    CGFloat panelWidth = MIN(350.0, maxW - 28.0);
    CGFloat maxPanelHeight = maxH - 20.0;
    CGFloat contentHeight = self.scrollView.contentSize.height;
    CGFloat panelHeight = MIN(contentHeight + 64.0, maxPanelHeight);

    CGFloat panelX = safeArea.origin.x + (maxW - panelWidth) / 2.0;
    CGFloat panelY = safeArea.origin.y + (maxH - panelHeight) / 2.0;

    self.panel.frame = CGRectMake(panelX, panelY, panelWidth, panelHeight);
    
    self.headerView.frame = CGRectMake(0, 0, panelWidth, 64);
    for (UIView *hSub in self.headerView.subviews) {
        if (hSub.tag == 999) {
            hSub.frame = CGRectMake(panelWidth - 44, 14, 36, 36);
        } else if (hSub.tag == TagTitle || hSub.tag == TagDetail) {
            CGRect f = hSub.frame;
            f.size.width = panelWidth - 60.0;
            hSub.frame = f;
        }
    }
    
    self.scrollView.frame = CGRectMake(0, 64, panelWidth, panelHeight - 64);
    
    for (UIView *sub in self.scrollView.subviews) {
        if (sub.tag == TagSection) {
            CGRect f = sub.frame;
            f.origin.x = 16.0;
            f.size.width = panelWidth - 32.0;
            sub.frame = f;
        } else if (sub.tag == TagRow) {
            CGRect rf = sub.frame;
            rf.origin.x = 14.0;
            rf.size.width = panelWidth - 28.0;
            sub.frame = rf;
            
            CGFloat switchWidth = 51.0;
            for (UIView *rSub in sub.subviews) {
                if ([rSub isKindOfClass:[UISwitch class]]) {
                    CGRect sf = rSub.frame;
                    sf.origin.x = rf.size.width - switchWidth - 12.0;
                    rSub.frame = sf;
                } else if (rSub.tag == TagTitle || rSub.tag == TagDetail) {
                    CGRect sf = rSub.frame;
                    sf.origin.x = 10.0;
                    sf.size.width = rf.size.width - switchWidth - 30.0;
                    rSub.frame = sf;
                }
            }
        } else if (sub.tag == TagSlider) {
            CGRect sf = sub.frame;
            sf.origin.x = 16.0;
            sf.size.width = panelWidth - 32.0;
            sub.frame = sf;
        } else if (sub.tag == TagValue) {
            CGRect sf = sub.frame;
            sf.origin.x = panelWidth - 80.0;
            sub.frame = sf;
        } else if ([sub isKindOfClass:[UILabel class]] && sub.tag != TagSection && sub.tag != TagValue) {
            CGRect sf = sub.frame;
            sf.origin.x = 16.0;
            sf.size.width = panelWidth - 95.0;
            sub.frame = sf;
        }
    }
}

- (CGFloat)addSectionHeader:(NSString *)title y:(CGFloat)y {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 300 - 32, 20)];
    lbl.tag = TagSection;
    lbl.text = title;
    lbl.textColor = [UIColor colorWithRed:0.40 green:0.70 blue:1.0 alpha:1];
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [self.scrollView addSubview:lbl];
    return y + 24;
}

- (CGFloat)addSwitchWithTitle:(NSString *)title detail:(NSString *)detail key:(NSString *)key y:(CGFloat)y on:(BOOL)isOn {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(14, y, 300 - 28, 44)];
    row.tag = TagRow;
    row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
    row.layer.cornerRadius = 10;
    [self.scrollView addSubview:row];

    UILabel *tLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, 190, 20)];
    tLbl.tag = TagTitle;
    tLbl.text = title;
    tLbl.textColor = UIColor.whiteColor;
    tLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [row addSubview:tLbl];

    UILabel *dLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 24, 190, 15)];
    dLbl.tag = TagDetail;
    dLbl.text = detail;
    dLbl.textColor = [UIColor colorWithWhite:0.60 alpha:1];
    dLbl.font = [UIFont systemFontOfSize:9];
    [row addSubview:dLbl];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(300 - 28 - 80, 7, 0, 0)];
    sw.on = isOn;
    sw.accessibilityIdentifier = key;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    return y + 50;
}

- (CGFloat)addSliderWithTitle:(NSString *)title key:(NSInteger)tag min:(float)min max:(float)max val:(float)val y:(CGFloat)y labelRef:(UILabel **)refLabel {
    UILabel *tLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 300 - 95, 18)];
    tLbl.text = title;
    tLbl.textColor = UIColor.whiteColor;
    tLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [self.scrollView addSubview:tLbl];

    UILabel *vLbl = [[UILabel alloc] initWithFrame:CGRectMake(300 - 80, y, 64, 18)];
    vLbl.tag = TagValue;
    vLbl.text = [NSString stringWithFormat:@"%.1f×", val];
    vLbl.textColor = [UIColor colorWithRed:0.42 green:0.85 blue:0.55 alpha:1];
    vLbl.textAlignment = NSTextAlignmentRight;
    vLbl.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
    [self.scrollView addSubview:vLbl];
    *refLabel = vLbl;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, y + 20, 300 - 32, 24)];
    slider.tag = TagSlider;
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = val;
    slider.tag = tag;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderTouchUp:) forControlEvents:UIControlEventTouchUpInside];
    [slider addTarget:self action:@selector(sliderTouchUp:) forControlEvents:UIControlEventTouchUpOutside];
    [slider addTarget:self action:@selector(sliderTouchUp:) forControlEvents:UIControlEventTouchCancel];
    [self.scrollView addSubview:slider];
    return y + 54;
}

- (void)toggleMenu {
    self.isOpen = !self.isOpen;
    if (self.isOpen) {
        self.panel.hidden = NO;
        self.panel.alpha = 0;
        self.panel.transform = CGAffineTransformMakeScale(0.95, 0.95);
        [UIView animateWithDuration:0.18 animations:^{
            self.panel.alpha = 1;
            self.panel.transform = CGAffineTransformIdentity;
        }];
        [self.view bringSubviewToFront:self.floatButton];
    } else {
        [UIView animateWithDuration:0.15 animations:^{
            self.panel.alpha = 0;
        } completion:^(BOOL finished) {
            self.panel.hidden = YES;
            self.panel.alpha = 1;
            self.panel.transform = CGAffineTransformIdentity;
        }];
    }
}

- (void)switchChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key) return;
    const char *cKey = [key UTF8String];
    if (!cKey) return;
    
    BOOL st = sender.on;
    {
        std::lock_guard<std::mutex> lock(g_StateMutex);
        if ([key isEqualToString:@"autoSkill"]) g_AllState.autoSkill = st;
        else if ([key isEqualToString:@"instantSkill"]) g_AllState.instantSkill = st;
        else if ([key isEqualToString:@"autoAttack"]) g_AllState.autoAttack = st;
        else if ([key isEqualToString:@"oneHit"]) g_AllState.oneHitKill = st;
        else if ([key isEqualToString:@"godMode"]) g_AllState.godMode = st;
        else if ([key isEqualToString:@"defense"]) g_AllState.defenseBoost = st;
        else if ([key isEqualToString:@"crit"]) g_AllState.critMultiplier = st;
        else if ([key isEqualToString:@"mapHack"]) g_AllState.mapHack = st;
    }
    
    if ([key isEqualToString:@"godMode"] && st) {
        CallGameFunction<void>(RVA_UDP_DEAD);
    } else if ([key isEqualToString:@"autoSkill"] && st) {
        CallGameFunction<void>(RVA_UDP_SKILL);
    } else if ([key isEqualToString:@"autoAttack"] && st) {
        CallGameFunction<void>(RVA_TCP_ATTACK);
    }

    LogAllMessage("Feature " + std::string(cKey) + " -> " + (st ? "ON" : "OFF"));
}

- (void)sliderChanged:(UISlider *)sender {
    float val = sender.value;
    {
        std::lock_guard<std::mutex> lock(g_StateMutex);
        if (sender.tag == 101) g_AllState.speedMultiplier = val;
        else if (sender.tag == 102) g_AllState.damageMultiplier = val;
        else if (sender.tag == 103) g_AllState.hpMultiplier = val;
        else if (sender.tag == 104) g_AllState.attackSpeedMultiplier = val;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender.tag == 101) self.speedLbl.text = [NSString stringWithFormat:@"%.1f×", val];
        else if (sender.tag == 102) self.dmgLbl.text = [NSString stringWithFormat:@"%.1f×", val];
        else if (sender.tag == 103) self.hpLbl.text = [NSString stringWithFormat:@"%.1f×", val];
        else if (sender.tag == 104) self.atkSpdLbl.text = [NSString stringWithFormat:@"%.1f×", val];
    });
}

- (void)sliderTouchUp:(UISlider *)sender {
    float val = sender.value;
    if (sender.tag == 101) {
        CallGameFunction<void, float>(RVA_ENTITY_SPEED, val);
        LogAllMessage("Speed Multiplier set to: " + std::to_string(val));
    } else if (sender.tag == 102) {
        CallGameFunction<void, float>(RVA_UDP_DAMAGE, val);
        LogAllMessage("Damage Multiplier set to: " + std::to_string(val));
    } else if (sender.tag == 103) {
        LogAllMessage("HP Multiplier set to: " + std::to_string(val));
    } else if (sender.tag == 104) {
        LogAllMessage("Attack Speed Multiplier set to: " + std::to_string(val));
    }
}

@end

static PassThroughWindow *g_AllWindow = nil;

__attribute__((constructor))
static void sheepct_all_entry(void) {
    InitAllLogger();
    LogAllMessage("Sheepct Tagged Layout Engine loaded.");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_AllWindow) return;
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (windowScene) {
            g_AllWindow = [[PassThroughWindow alloc] initWithWindowScene:windowScene];
        } else {
            g_AllWindow = [[PassThroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        }
        g_AllWindow.windowLevel = UIWindowLevelAlert + 999;
        g_AllWindow.backgroundColor = UIColor.clearColor;
        g_AllWindow.rootViewController = [[AllFeatureMenuController alloc] init];
        g_AllWindow.userInteractionEnabled = YES;
        g_AllWindow.hidden = NO;
    });
}
