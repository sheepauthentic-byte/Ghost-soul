// Language: Objective-C++ (C++17)
// Target: iOS non-jailbroken Mach-O (Unity/IL2CPP dynamic library)
// Compiler: clang++ (Makefile/GitHub Actions workflow compliant)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <string>
#include <fstream>
#include <mutex>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <limits>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/getsect.h>
#include <dlfcn.h>

extern "C" {
    int DobbyHook(void *address, void *replace, void **backup);
    int DobbyDestroy(void *address);
}

// ============================================================
// CONFIGURATION & GAME HOOK RVAS
// ============================================================

static NSString * const kLogFileName = @"sheepct.log";

// Verified Game RVAs (GhostSoulM / UnityFramework)
#define RVA_ENTITY_SPEED      0x19ce918 // void EntityAIPlayer::SetfSpeed(void* instance, float speed)
#define RVA_UDP_DEAD          0x1748fbc // void UdpClient::SendPlayerDead_C(void* instance)
#define RVA_UDP_DAMAGE        0x1744888 // void UdpClient::SendPlayerDamage_C(void* instance, float damage)
#define RVA_UDP_DEFENSE       0x1747348 // void UdpClient::SendPlayerDefence_C(void* instance, float defense)
#define RVA_ENTITY_HP         0x19cf020 // void EntityAIPlayer::SetfMaxHP(void* instance, float hp)
#define RVA_ENTITY_ATKSPD     0x19cf410 // void EntityAIPlayer::SetfAttackSpeed(void* instance, float atkSpd)
#define RVA_UDP_SKILL         0x1743c2c // void UdpClient::SendPlayerSkill_C(void* instance)
#define RVA_UDP_ATTACK        0x1747508 // void UdpClient::SendPlayerAttack(void* instance)

enum : NSInteger {
    TagSection = 700,
    TagRow = 701,
    TagTitle = 702,
    TagDetail = 703,
    TagSliderTitle = 705,
    TagValue = 888
};

// ============================================================
// THREAD-SAFE LOGGER
// ============================================================

class SafeLogger {
private:
    std::mutex mutex_;
    std::ofstream stream_;

    SafeLogger() = default;

public:
    SafeLogger(const SafeLogger &) = delete;
    SafeLogger &operator=(const SafeLogger &) = delete;

    static SafeLogger &shared() {
        static SafeLogger instance;
        return instance;
    }

    void initialize() {
        std::lock_guard<std::mutex> lock(mutex_);

        if (stream_.is_open())
            return;

        @autoreleasepool {
            NSArray *paths =
                NSSearchPathForDirectoriesInDomains(
                    NSDocumentDirectory,
                    NSUserDomainMask,
                    YES
                );

            if (paths.count == 0)
                return;

            NSString *path =
                [paths.firstObject stringByAppendingPathComponent:kLogFileName];

            const char *filePath = path.fileSystemRepresentation;

            if (!filePath)
                return;

            stream_.open(filePath, std::ios::out | std::ios::app);
        }
    }

    void write(const std::string &message) {
        std::lock_guard<std::mutex> lock(mutex_);

        if (!stream_.is_open())
            return;

        @autoreleasepool {
            NSDateFormatter *formatter =
                [[NSDateFormatter alloc] init];

            formatter.locale =
                [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

            NSString *date =
                [formatter stringFromDate:[NSDate date]];

            const char *dateString = date.UTF8String;

            stream_
                << "["
                << (dateString ? dateString : "unknown")
                << "] "
                << message
                << '\n';

            stream_.flush();
        }
    }

    ~SafeLogger() {
        std::lock_guard<std::mutex> lock(mutex_);

        if (stream_.is_open())
            stream_.close();
    }
};

#define LOG_MESSAGE(x) SafeLogger::shared().write(x)

// ============================================================
// THREAD-SAFE SETTINGS & MOD STATE
// ============================================================

struct MenuSettings {
    bool showFPS = false;
    bool compactMode = false;
    bool showDiagnostics = true;

    // Feature Toggles
    bool godMode = false;
    bool autoSkill = false;
    bool autoAttack = false;
    bool defenseBoost = false;

    // Numerical Multipliers
    float speedMultiplier = 1.0f;
    float damageMultiplier = 1.0f;
    float hpMultiplier = 1.0f;
    float attackSpeedMultiplier = 1.0f;

    float scale = 1.0f;
    float opacity = 0.95f;
};

struct HookState {
    bool speedInstalled = false;
    bool deadInstalled = false;
    bool damageInstalled = false;
    bool defenseInstalled = false;
    bool hpInstalled = false;
    bool atkSpeedInstalled = false;
    bool skillInstalled = false;
    bool attackInstalled = false;
};

static HookState g_HookStatus;

class SettingsStore {
private:
    std::mutex mutex_;
    MenuSettings settings_;

public:
    static SettingsStore &shared() {
        static SettingsStore instance;
        return instance;
    }

    MenuSettings snapshot() {
        std::lock_guard<std::mutex> lock(mutex_);
        return settings_;
    }

    void update(const MenuSettings &value) {
        std::lock_guard<std::mutex> lock(mutex_);
        settings_ = value;
    }

    template<typename Callback>
    void modify(Callback callback) {
        std::lock_guard<std::mutex> lock(mutex_);
        callback(settings_);
    }
};

// ============================================================
// SAFE MACH-O INSPECTION & HOOK RESOLUTION
// ============================================================

static uintptr_t GetVerifiedTargetAddress(uintptr_t rva) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "UnityFramework") || strstr(name, "GhostSoulM"))) {
            const mach_header *rawHeader = _dyld_get_image_header(i);
            if (rawHeader && rawHeader->magic == MH_MAGIC_64) {
                const auto *header = reinterpret_cast<const mach_header_64 *>(rawHeader);
                uintptr_t slide = _dyld_get_image_vmaddr_slide(i);
                
                unsigned long size = 0;
                uint8_t *section = getsectiondata(header, "__TEXT", "__text", &size);
                if (section && size > 0) {
                    uintptr_t candidate = (uintptr_t)header + slide + rva;
                    uintptr_t sectStart = (uintptr_t)section + slide;
                    uintptr_t sectEnd = sectStart + size;
                    
                    if (candidate >= sectStart && candidate < sectEnd) {
                        return candidate;
                    }
                }
            }
        }
    }
    return 0;
}

// Function Pointers for Original Game Methods
typedef void (*OriginalSetfSpeed)(void *instance, float speed);
typedef void (*OriginalSendPlayerDead)(void *instance);
typedef void (*OriginalSendPlayerDamage)(void *instance, float damage);
typedef void (*OriginalSendPlayerDefence)(void *instance, float defense);
typedef void (*OriginalSetfMaxHP)(void *instance, float hp);
typedef void (*OriginalSetfAttackSpeed)(void *instance, float atkSpd);
typedef void (*OriginalSendPlayerSkill)(void *instance);
typedef void (*OriginalSendPlayerAttack)(void *instance);

static OriginalSetfSpeed orig_SetfSpeed = nullptr;
static OriginalSendPlayerDead orig_SendPlayerDead = nullptr;
static OriginalSendPlayerDamage orig_SendPlayerDamage = nullptr;
static OriginalSendPlayerDefence orig_SendPlayerDefence = nullptr;
static OriginalSetfMaxHP orig_SetfMaxHP = nullptr;
static OriginalSetfAttackSpeed orig_SetfAttackSpeed = nullptr;
static OriginalSendPlayerSkill orig_SendPlayerSkill = nullptr;
static OriginalSendPlayerAttack orig_SendPlayerAttack = nullptr;

// Live Hook Replacements
void hooked_SetfSpeed(void *instance, float speed) {
    if (instance != nullptr) {
        MenuSettings s = SettingsStore::shared().snapshot();
        speed *= s.speedMultiplier;
    }
    if (orig_SetfSpeed) orig_SetfSpeed(instance, speed);
}

void hooked_SendPlayerDead(void *instance) {
    MenuSettings s = SettingsStore::shared().snapshot();
    if (s.godMode && instance != nullptr) {
        return; // Suppress death call transmission
    }
    if (orig_SendPlayerDead) orig_SendPlayerDead(instance);
}

void hooked_SendPlayerDamage(void *instance, float damage) {
    if (instance != nullptr) {
        MenuSettings s = SettingsStore::shared().snapshot();
        damage *= s.damageMultiplier;
    }
    if (orig_SendPlayerDamage) orig_SendPlayerDamage(instance, damage);
}

void hooked_SendPlayerDefence(void *instance, float defense) {
    if (instance != nullptr) {
        MenuSettings s = SettingsStore::shared().snapshot();
        if (s.defenseBoost) {
            defense *= 5.0f;
        }
    }
    if (orig_SendPlayerDefence) orig_SendPlayerDefence(instance, defense);
}

void hooked_SetfMaxHP(void *instance, float hp) {
    if (instance != nullptr) {
        MenuSettings s = SettingsStore::shared().snapshot();
        hp *= s.hpMultiplier;
    }
    if (orig_SetfMaxHP) orig_SetfMaxHP(instance, hp);
}

void hooked_SetfAttackSpeed(void *instance, float atkSpd) {
    if (instance != nullptr) {
        MenuSettings s = SettingsStore::shared().snapshot();
        atkSpd *= s.attackSpeedMultiplier;
    }
    if (orig_SetfAttackSpeed) orig_SetfAttackSpeed(instance, atkSpd);
}

void hooked_SendPlayerSkill(void *instance) {
    MenuSettings s = SettingsStore::shared().snapshot();
    if (s.autoSkill && instance != nullptr && orig_SendPlayerSkill) {
        orig_SendPlayerSkill(instance); // Secondary pulse execution
    }
    if (orig_SendPlayerSkill) orig_SendPlayerSkill(instance);
}

void hooked_SendPlayerAttack(void *instance) {
    MenuSettings s = SettingsStore::shared().snapshot();
    if (s.autoAttack && instance != nullptr && orig_SendPlayerAttack) {
        orig_SendPlayerAttack(instance); // Double-stream execution
    }
    if (orig_SendPlayerAttack) orig_SendPlayerAttack(instance);
}

static void SetupRuntimeHooksWithRetry(int retriesLeft) {
    if (!g_HookStatus.speedInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_ENTITY_SPEED);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SetfSpeed, (void**)&orig_SetfSpeed) == 0) {
            g_HookStatus.speedInstalled = true;
            LOG_MESSAGE("Success: Hooked EntityAIPlayer::SetfSpeed");
        }
    }

    if (!g_HookStatus.deadInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_UDP_DEAD);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SendPlayerDead, (void**)&orig_SendPlayerDead) == 0) {
            g_HookStatus.deadInstalled = true;
            LOG_MESSAGE("Success: Hooked UdpClient::SendPlayerDead_C");
        }
    }

    if (!g_HookStatus.damageInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_UDP_DAMAGE);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SendPlayerDamage, (void**)&orig_SendPlayerDamage) == 0) {
            g_HookStatus.damageInstalled = true;
            LOG_MESSAGE("Success: Hooked UdpClient::SendPlayerDamage_C");
        }
    }

    if (!g_HookStatus.defenseInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_UDP_DEFENSE);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SendPlayerDefence, (void**)&orig_SendPlayerDefence) == 0) {
            g_HookStatus.defenseInstalled = true;
            LOG_MESSAGE("Success: Hooked UdpClient::SendPlayerDefence_C");
        }
    }

    if (!g_HookStatus.hpInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_ENTITY_HP);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SetfMaxHP, (void**)&orig_SetfMaxHP) == 0) {
            g_HookStatus.hpInstalled = true;
            LOG_MESSAGE("Success: Hooked EntityAIPlayer::SetfMaxHP");
        }
    }

    if (!g_HookStatus.atkSpeedInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_ENTITY_ATKSPD);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SetfAttackSpeed, (void**)&orig_SetfAttackSpeed) == 0) {
            g_HookStatus.atkSpeedInstalled = true;
            LOG_MESSAGE("Success: Hooked EntityAIPlayer::SetfAttackSpeed");
        }
    }

    if (!g_HookStatus.skillInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_UDP_SKILL);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SendPlayerSkill, (void**)&orig_SendPlayerSkill) == 0) {
            g_HookStatus.skillInstalled = true;
            LOG_MESSAGE("Success: Hooked UdpClient::SendPlayerSkill_C");
        }
    }

    if (!g_HookStatus.attackInstalled) {
        uintptr_t addr = GetVerifiedTargetAddress(RVA_UDP_ATTACK);
        if (addr != 0 && DobbyHook((void*)addr, (void*)hooked_SendPlayerAttack, (void**)&orig_SendPlayerAttack) == 0) {
            g_HookStatus.attackInstalled = true;
            LOG_MESSAGE("Success: Hooked UdpClient::SendPlayerAttack");
        }
    }

    int activeCount = (g_HookStatus.speedInstalled ? 1 : 0) +
                      (g_HookStatus.deadInstalled ? 1 : 0) +
                      (g_HookStatus.damageInstalled ? 1 : 0) +
                      (g_HookStatus.defenseInstalled ? 1 : 0) +
                      (g_HookStatus.hpInstalled ? 1 : 0) +
                      (g_HookStatus.atkSpeedInstalled ? 1 : 0) +
                      (g_HookStatus.skillInstalled ? 1 : 0) +
                      (g_HookStatus.attackInstalled ? 1 : 0);

    if (activeCount < 8 && retriesLeft > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SetupRuntimeHooksWithRetry(retriesLeft - 1);
        });
    }
}

// ============================================================
// OVERLAY WINDOW
// ============================================================

@interface PassThroughWindow : UIWindow
@end

@implementation PassThroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];

    if (hit == self || hit == self.rootViewController.view)
        return nil;

    return hit;
}

@end

// ============================================================
// MENU CONTROLLER
// ============================================================

@interface OverlayController : UIViewController

@property(nonatomic,strong) UIButton *floatButton;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UIView *header;
@property(nonatomic,strong) UIScrollView *scrollView;

@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *scaleLabel;
@property(nonatomic,strong) UILabel *opacityLabel;
@property(nonatomic,strong) UILabel *speedLabel;
@property(nonatomic,strong) UILabel *damageLabel;
@property(nonatomic,strong) UILabel *hpLabel;
@property(nonatomic,strong) UILabel *atkSpeedLabel;

@property(nonatomic,strong) NSTimer *statusTimer;

@property(nonatomic,assign) BOOL isOpen;
@property(nonatomic,assign) BOOL didDrag;
@property(nonatomic,assign) CGPoint dragStartTouchPoint;

@end

@implementation OverlayController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.clearColor;

    [self buildPanel];
    [self buildFloatingButton];

    self.statusTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(refreshStatus)
                                       userInfo:nil
                                        repeats:YES];

    [self refreshStatus];
}

- (void)dealloc {
    [self.statusTimer invalidate];
    self.statusTimer = nil;
}

- (void)refreshStatus {
    if (!self.statusLabel)
        return;

    int count = (g_HookStatus.speedInstalled ? 1 : 0) +
                (g_HookStatus.deadInstalled ? 1 : 0) +
                (g_HookStatus.damageInstalled ? 1 : 0) +
                (g_HookStatus.defenseInstalled ? 1 : 0) +
                (g_HookStatus.hpInstalled ? 1 : 0) +
                (g_HookStatus.atkSpeedInstalled ? 1 : 0) +
                (g_HookStatus.skillInstalled ? 1 : 0) +
                (g_HookStatus.attackInstalled ? 1 : 0);

    self.statusLabel.text =
        [NSString stringWithFormat:@"Hooks: %d/8", count];

    self.statusLabel.textColor =
        (count == 8)
        ? [UIColor colorWithRed:0.42 green:0.85 blue:0.55 alpha:1]
        : [UIColor colorWithRed:0.95 green:0.65 blue:0.25 alpha:1];
}

// ------------------------------------------------------------
// FLOATING BUTTON
// ------------------------------------------------------------

- (void)buildFloatingButton {
    self.floatButton =
        [UIButton buttonWithType:UIButtonTypeCustom];

    self.floatButton.frame =
        CGRectMake(18, 130, 58, 58);

    self.floatButton.backgroundColor =
        [UIColor colorWithRed:0.15
                        green:0.40
                         blue:0.90
                        alpha:0.96];

    [self.floatButton setTitle:@"ALL"
                      forState:UIControlStateNormal];

    self.floatButton.titleLabel.font =
        [UIFont systemFontOfSize:15
                          weight:UIFontWeightHeavy];

    self.floatButton.layer.cornerRadius = 29;
    self.floatButton.layer.borderWidth = 2;
    self.floatButton.layer.borderColor =
        UIColor.whiteColor.CGColor;

    [self.floatButton addTarget:self
                         action:@selector(buttonDown:withEvent:)
               forControlEvents:UIControlEventTouchDown];

    [self.floatButton addTarget:self
                         action:@selector(buttonDragged:withEvent:)
               forControlEvents:
                   UIControlEventTouchDragInside |
                   UIControlEventTouchDragOutside];

    [self.floatButton addTarget:self
                         action:@selector(buttonTapped:)
               forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:self.floatButton];
}

- (void)buttonDown:(UIButton *)button
        withEvent:(UIEvent *)event {

    self.didDrag = NO;

    UITouch *touch = event.allTouches.anyObject;

    if (touch)
        self.dragStartTouchPoint = [touch locationInView:self.view];
}

- (void)buttonDragged:(UIButton *)button
            withEvent:(UIEvent *)event {

    UITouch *touch = event.allTouches.anyObject;

    if (!touch)
        return;

    CGPoint current = [touch locationInView:self.view];

    CGFloat distance =
        hypot(
            current.x - self.dragStartTouchPoint.x,
            current.y - self.dragStartTouchPoint.y
        );

    if (distance > 5.0)
        self.didDrag = YES;

    if (!self.didDrag)
        return;

    CGPoint previous =
        [touch previousLocationInView:self.view];

    CGPoint center = button.center;

    center.x += current.x - previous.x;
    center.y += current.y - previous.y;

    UIEdgeInsets insets = self.view.safeAreaInsets;

    CGFloat halfW = CGRectGetWidth(button.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(button.bounds) / 2.0;

    CGFloat minX = insets.left + halfW;
    CGFloat maxX = CGRectGetWidth(self.view.bounds)
                 - insets.right - halfW;

    CGFloat minY = insets.top + halfH;
    CGFloat maxY = CGRectGetHeight(self.view.bounds)
                 - insets.bottom - halfH;

    center.x = MAX(minX, MIN(maxX, center.x));
    center.y = MAX(minY, MIN(maxY, center.y));

    button.center = center;
}

- (void)buttonTapped:(UIButton *)button {
    if (!self.didDrag)
        [self toggleMenu];
}

// ------------------------------------------------------------
// PANEL
// ------------------------------------------------------------

- (void)buildPanel {
    self.panel = [[UIView alloc]
        initWithFrame:CGRectZero];

    self.panel.backgroundColor =
        [UIColor colorWithRed:0.07
                        green:0.08
                         blue:0.12
                        alpha:0.98];

    self.panel.layer.cornerRadius = 18;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor =
        [UIColor colorWithWhite:1 alpha:0.2].CGColor;

    self.panel.clipsToBounds = YES;
    self.panel.hidden = YES;

    [self.view addSubview:self.panel];

    self.header = [[UIView alloc]
        initWithFrame:CGRectZero];

    self.header.backgroundColor =
        [UIColor colorWithRed:0.11
                        green:0.16
                         blue:0.25
                        alpha:1];

    [self.panel addSubview:self.header];

    UILabel *title =
        [[UILabel alloc] initWithFrame:CGRectZero];

    title.tag = TagTitle;
    title.text = @"SHEEPCT • HOOK ENGINE";
    title.textColor = UIColor.whiteColor;
    title.font =
        [UIFont systemFontOfSize:13
                          weight:UIFontWeightBold];

    [self.header addSubview:title];

    self.statusLabel =
        [[UILabel alloc] initWithFrame:CGRectZero];

    self.statusLabel.textColor =
        [UIColor colorWithRed:0.42
                        green:0.85
                         blue:0.55
                        alpha:1];

    self.statusLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:10
                                         weight:UIFontWeightBold];

    self.statusLabel.textAlignment = NSTextAlignmentRight;

    [self.header addSubview:self.statusLabel];

    UIButton *close =
        [UIButton buttonWithType:UIButtonTypeSystem];

    [close setTitle:@"×"
           forState:UIControlStateNormal];

    [close setTitleColor:UIColor.whiteColor
                forState:UIControlStateNormal];

    close.titleLabel.font =
        [UIFont systemFontOfSize:25
                          weight:UIFontWeightRegular];

    [close addTarget:self
              action:@selector(toggleMenu)
    forControlEvents:UIControlEventTouchUpInside];

    [self.header addSubview:close];

    self.scrollView =
        [[UIScrollView alloc] initWithFrame:CGRectZero];

    self.scrollView.alwaysBounceVertical = YES;

    [self.panel addSubview:self.scrollView];

    [self buildSettings];
}

- (void)buildSettings {
    MenuSettings settings =
        SettingsStore::shared().snapshot();

    CGFloat y = 14;

    y = [self addSection:@"1. Combat & Defense" y:y];

    y = [self addSwitch:@"Bất tử / God Mode"
                    key:@"godMode"
                     on:settings.godMode
                      y:y];

    y = [self addSwitch:@"Tự động Kỹ năng"
                    key:@"autoSkill"
                     on:settings.autoSkill
                      y:y];

    y = [self addSwitch:@"Tấn công tự động"
                    key:@"autoAttack"
                     on:settings.autoAttack
                      y:y];

    y = [self addSwitch:@"Tăng cường Phòng thủ"
                    key:@"defense"
                     on:settings.defenseBoost
                      y:y];

    y = [self addSection:@"2. Speed & Multipliers" y:y];

    y = [self addSlider:@"Hệ số Tốc độ (Speed)"
                  value:settings.speedMultiplier
                    min:1.0
                   max:10.0
                      y:y
                   tag:101
             reference:&_speedLabel];

    y = [self addSlider:@"Hệ số Sát thương (Damage)"
                  value:settings.damageMultiplier
                    min:1.0
                   max:20.0
                      y:y
                   tag:102
             reference:&_damageLabel];

    y = [self addSlider:@"Hệ số Máu (HP)"
                  value:settings.hpMultiplier
                    min:1.0
                   max:10.0
                      y:y
                   tag:103
             reference:&_hpLabel];

    y = [self addSlider:@"Tốc độ Đánh (Atk Speed)"
                  value:settings.attackSpeedMultiplier
                    min:1.0
                   max:5.0
                      y:y
                   tag:104
             reference:&_atkSpeedLabel];

    y = [self addSection:@"3. UI & Scale" y:y];

    y = [self addSlider:@"Kích thước giao diện"
                  value:settings.scale
                    min:0.7
                   max:1.3
                      y:y
                   tag:201
             reference:&_scaleLabel];

    y = [self addSlider:@"Độ trong suốt"
                  value:settings.opacity
                    min:0.3
                   max:1.0
                      y:y
                   tag:202
             reference:&_opacityLabel];

    self.scrollView.contentSize =
        CGSizeMake(320, y + 20);
}

- (CGFloat)addSection:(NSString *)text y:(CGFloat)y {
    UILabel *label =
        [[UILabel alloc] initWithFrame:CGRectMake(16, y, 280, 22)];

    label.tag = TagSection;
    label.text = text;
    label.textColor =
        [UIColor colorWithRed:0.4
                        green:0.7
                         blue:1
                        alpha:1];

    label.font =
        [UIFont systemFontOfSize:12
                          weight:UIFontWeightBold];

    [self.scrollView addSubview:label];

    return y + 28;
}

- (CGFloat)addSwitch:(NSString *)title
                 key:(NSString *)key
                  on:(BOOL)value
                   y:(CGFloat)y {

    UIView *row =
        [[UIView alloc]
            initWithFrame:CGRectMake(14, y, 292, 48)];

    row.tag = TagRow;
    row.backgroundColor =
        [UIColor colorWithWhite:1 alpha:0.05];

    row.layer.cornerRadius = 10;

    [self.scrollView addSubview:row];

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:CGRectMake(10, 0, 205, 48)];

    label.tag = TagTitle;
    label.text = title;
    label.textColor = UIColor.whiteColor;
    label.font =
        [UIFont systemFontOfSize:12
                          weight:UIFontWeightSemibold];

    [row addSubview:label];

    UISwitch *toggle =
        [[UISwitch alloc] initWithFrame:CGRectZero];

    toggle.on = value;
    toggle.accessibilityIdentifier = key;

    [toggle addTarget:self
               action:@selector(switchChanged:)
     forControlEvents:UIControlEventValueChanged];

    [row addSubview:toggle];

    return y + 54;
}

- (CGFloat)addSlider:(NSString *)title
               value:(float)value
                 min:(float)minimum
                 max:(float)maximum
                   y:(CGFloat)y
                 tag:(NSInteger)tag
           reference:(UILabel **)refLabel {

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:CGRectMake(16, y, 220, 20)];

    label.tag = TagSliderTitle;
    label.text = title;
    label.textColor = UIColor.whiteColor;
    label.font =
        [UIFont systemFontOfSize:11
                          weight:UIFontWeightSemibold];

    [self.scrollView addSubview:label];

    UILabel *valueLabel =
        [[UILabel alloc]
            initWithFrame:CGRectMake(240, y, 60, 20)];

    valueLabel.tag = TagValue;
    valueLabel.text =
        [NSString stringWithFormat:@"%.1f×", value];

    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.textColor =
        [UIColor colorWithRed:0.42 green:0.85 blue:0.55 alpha:1];

    valueLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:11
                                         weight:UIFontWeightBold];

    [self.scrollView addSubview:valueLabel];

    if (refLabel)
        *refLabel = valueLabel;

    UISlider *slider =
        [[UISlider alloc]
            initWithFrame:CGRectMake(16, y + 22, 288, 30)];

    slider.minimumValue = minimum;
    slider.maximumValue = maximum;
    slider.value = value;
    slider.tag = tag;

    [slider addTarget:self
               action:@selector(sliderChanged:)
     forControlEvents:UIControlEventValueChanged];

    [self.scrollView addSubview:slider];

    return y + 62;
}

// ------------------------------------------------------------
// INTERACTION
// ------------------------------------------------------------

- (void)switchChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;

    SettingsStore::shared().modify(
        [&](MenuSettings &settings) {
            if ([key isEqualToString:@"godMode"])
                settings.godMode = sender.on;
            else if ([key isEqualToString:@"autoSkill"])
                settings.autoSkill = sender.on;
            else if ([key isEqualToString:@"autoAttack"])
                settings.autoAttack = sender.on;
            else if ([key isEqualToString:@"defense"])
                settings.defenseBoost = sender.on;
        }
    );

    LOG_MESSAGE(
        std::string("Feature ") +
        key.UTF8String +
        (sender.on ? " -> ON" : " -> OFF")
    );
}

- (void)sliderChanged:(UISlider *)sender {
    float value = sender.value;
    NSInteger tag = sender.tag;

    SettingsStore::shared().modify(
        [&](MenuSettings &settings) {
            if (tag == 101)
                settings.speedMultiplier = value;
            else if (tag == 102)
                settings.damageMultiplier = value;
            else if (tag == 103)
                settings.hpMultiplier = value;
            else if (tag == 104)
                settings.attackSpeedMultiplier = value;
            else if (tag == 201)
                settings.scale = value;
            else if (tag == 202)
                settings.opacity = value;
        }
    );

    UILabel *targetLabel = nil;
    if (tag == 101) targetLabel = self.speedLabel;
    else if (tag == 102) targetLabel = self.damageLabel;
    else if (tag == 103) targetLabel = self.hpLabel;
    else if (tag == 104) targetLabel = self.atkSpeedLabel;
    else if (tag == 201) targetLabel = self.scaleLabel;
    else if (tag == 202) targetLabel = self.opacityLabel;

    if (targetLabel) {
        if (tag >= 201) {
            targetLabel.text = [NSString stringWithFormat:@"%.2f", value];
        } else {
            targetLabel.text = [NSString stringWithFormat:@"%.1f×", value];
        }
    }

    MenuSettings settings =
        SettingsStore::shared().snapshot();

    self.panel.alpha = settings.opacity;

    self.panel.transform =
        CGAffineTransformMakeScale(
            settings.scale,
            settings.scale
        );
}

- (void)toggleMenu {
    self.isOpen = !self.isOpen;

    if (self.isOpen) {
        self.panel.hidden = NO;
        self.panel.alpha = 1;

        [self.view bringSubviewToFront:self.floatButton];
    } else {
        self.panel.hidden = YES;
    }
}

// ------------------------------------------------------------
// RESPONSIVE LAYOUT
// ------------------------------------------------------------

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;

    CGFloat width =
        MAX(1, bounds.size.width - safe.left - safe.right);

    CGFloat height =
        MAX(1, bounds.size.height - safe.top - safe.bottom);

    CGFloat panelWidth = MIN(350, MAX(1, width - 20));
    CGFloat panelHeight = MIN(
        height - 20,
        self.scrollView.contentSize.height + 64
    );

    panelHeight = MAX(150, panelHeight);

    CGFloat x =
        safe.left + (width - panelWidth) / 2;

    CGFloat y =
        safe.top + (height - panelHeight) / 2;

    self.panel.frame =
        CGRectMake(x, y, panelWidth, panelHeight);

    self.header.frame =
        CGRectMake(0, 0, panelWidth, 64);

    self.scrollView.frame =
        CGRectMake(
            0,
            64,
            panelWidth,
            MAX(0, panelHeight - 64)
        );

    for (UIView *view in self.header.subviews) {
        if ([view isKindOfClass:UILabel.class]) {
            if (view == self.statusLabel) {
                view.frame =
                    CGRectMake(
                        panelWidth - 130,
                        8,
                        114,
                        20
                    );
            } else {
                view.frame =
                    CGRectMake(16, 8, panelWidth - 140, 20);
            }
        } else if ([view isKindOfClass:UIButton.class]) {
            view.frame =
                CGRectMake(panelWidth - 44, 14, 36, 36);
        }
    }

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
        } else if ((sub.tag >= 101 && sub.tag <= 104) || (sub.tag >= 201 && sub.tag <= 202)) {
            CGRect sf = sub.frame;
            sf.origin.x = 16.0;
            sf.size.width = panelWidth - 32.0;
            sub.frame = sf;
        } else if (sub.tag == TagValue) {
            CGRect sf = sub.frame;
            sf.origin.x = panelWidth - 80.0;
            sub.frame = sf;
        } else if (sub.tag == TagSliderTitle) {
            CGRect sf = sub.frame;
            sf.origin.x = 16.0;
            sf.size.width = panelWidth - 95.0;
            sub.frame = sf;
        }
    }
}

@end

// ============================================================
// WINDOW MANAGEMENT (DIRECT FALLBACK)
// ============================================================

static PassThroughWindow *gOverlayWindow = nil;

static void PresentOverlay(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PresentOverlay();
        });
        return;
    }

    if (gOverlayWindow)
        return;

    UIWindowScene *activeScene = nil;

    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] &&
                scene.activationState ==
                    UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
    } @catch (__unused NSException *e) {}

    if (activeScene) {
        gOverlayWindow =
            [[PassThroughWindow alloc]
                initWithWindowScene:activeScene];
        gOverlayWindow.frame = activeScene.coordinateSpace.bounds;
    } else {
        gOverlayWindow =
            [[PassThroughWindow alloc]
                initWithFrame:UIScreen.mainScreen.bounds];
    }

    gOverlayWindow.backgroundColor = UIColor.clearColor;
    gOverlayWindow.windowLevel = UIWindowLevelAlert + 999;
    gOverlayWindow.rootViewController =
        [[OverlayController alloc] init];
    gOverlayWindow.hidden = NO;

    LOG_MESSAGE("Overlay initialized via direct fallback window.");
}

// ============================================================
// ENTRY POINT (INSTANT SYNC MOUNT)
// ============================================================

__attribute__((constructor))
static void sheepct_entry(void) {
    @autoreleasepool {
        SafeLogger::shared().initialize();
        LOG_MESSAGE("Single-file Objective-C++ module loaded with instant mount.");

        // Ép chạy trực tiếp trên Main Queue ngay lập tức không delay
        dispatch_async(dispatch_get_main_queue(), ^{
            PresentOverlay();
        });

        // Kích hoạt hook ngầm sau 2 giây khi game đã ổn định ngữ cảnh bộ nhớ
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SetupRuntimeHooksWithRetry(3);
        });
    }
}
