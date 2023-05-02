# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2023 Rother OSS GmbH, https://otobo.de/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::Output::HTML::Layout;

use v5.24;
use strict;
use warnings;
use namespace::autoclean;
use utf8;

# core modules
use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(blessed);

# CPAN modules
use URI::Escape qw(uri_escape_utf8);
use Plack::Response;
use Plack::Util;

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);
use Kernel::System::Web::Exception;
use Kernel::Language qw(Translatable);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::Language',
    'Kernel::System::AuthSession',
    'Kernel::System::Cache',
    'Kernel::System::Chat',
    'Kernel::System::CustomerGroup',
    'Kernel::System::CustomerUser',
    'Kernel::System::DateTime',
    'Kernel::System::Group',
    'Kernel::System::Encode',
    'Kernel::System::HTMLUtils',
    'Kernel::System::JSON',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::System::State',
    'Kernel::System::Storable',
    'Kernel::System::SystemMaintenance',
    'Kernel::System::User',
    'Kernel::System::VideoChat',
    'Kernel::System::Web::Request',
    'Kernel::System::Web::Response',
);

=head1 NAME

Kernel::Output::HTML::Layout - all generic HTML functions

=head1 DESCRIPTION

All generic HTML functions. E. g. to get options fields, template processing, ...

=head1 PUBLIC INTERFACE

=head2 new()

create a new object. Do not use it directly, instead use:

    use Kernel::System::ObjectManager;
    local $Kernel::OM = Kernel::System::ObjectManager->new(
        'Kernel::Output::HTML::Layout' => {
            Lang    => 'de',
        },
    );
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    # %Param often has a entry for 'SetCookies'
    my $Self = bless {%Param}, $Type;

    # set defaults
    $Self->{Debug} = 0;
    $Self->{SetCookies} //= {};

    # reset block data
    delete $Self->{BlockData};

    # empty action if not defined
    $Self->{Action} //= '';

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # get/set some common params
    $Self->{UserTheme}    ||= $ConfigObject->Get('DefaultTheme');
    $Self->{UserTimeZone} ||= Kernel::System::DateTime->UserDefaultTimeZoneGet();

    # Determine the language to use based on the browser setting, if there isn't one yet.
    my $ParamObject = $Kernel::OM->Get('Kernel::System::Web::Request');
    if ( !$Self->{UserLanguage} ) {
        my @BrowserLanguages = split /\s*,\s*/, $Self->{Lang} || $ParamObject->Header('Accept-Language') || '';
        my %Data = %{ $ConfigObject->Get('DefaultUsedLanguages') };

        LANGUAGE:
        for my $BrowserLang (@BrowserLanguages) {
            for my $Language ( reverse sort keys %Data ) {

                # check xx_XX and xx-XX type
                my $LanguageOtherType = $Language;
                $LanguageOtherType =~ s/_/-/;
                if ( $BrowserLang =~ /^($Language|$LanguageOtherType)/i ) {
                    $Self->{UserLanguage} = $Language;
                    last LANGUAGE;
                }
            }
            if ( !$Self->{UserLanguage} ) {
                for my $Language ( reverse sort keys %Data ) {

                    # If Browser requests 'vi', also offer 'vi_VI' even though we don't have 'vi'
                    if ( $Language =~ m/^$BrowserLang/smxi ) {
                        $Self->{UserLanguage} = $Language;
                        last LANGUAGE;
                    }
                }
            }
        }
        $Self->{UserLanguage} ||= $ConfigObject->Get('DefaultLanguage') || 'en';
    }

    # create language object
    if ( !$Self->{LanguageObject} ) {
        $Kernel::OM->ObjectParamAdd(
            'Kernel::Language' => {
                UserTimeZone => $Self->{UserTimeZone},
                UserLanguage => $Self->{UserLanguage},
                Action       => $Self->{Action},
            },
        );
        $Self->{LanguageObject} = $Kernel::OM->Get('Kernel::Language');
    }

    # set charset if there is no charset given
    $Self->{UserCharset} = 'utf-8';                 # used directly by frontend modules
    $Self->{Charset}     = $Self->{UserCharset};    # just for compatibility, used directly by frontend modules
    $Self->{SessionID}   = $Param{SessionID}          || '';
    $Self->{SessionName} = $Param{SessionName}        || 'SessionID';
    $Self->{CGIHandle}   = $ParamObject->ScriptName() || 'No-$ENV{"SCRIPT_NAME"}';

    # baselink
    $Self->{Baselink} = $Self->{CGIHandle} . '?';
    $Self->{Time}     = $Self->{LanguageObject}->Time(
        Action => 'GET',
        Format => 'DateFormat',
    );
    $Self->{TimeLong} = $Self->{LanguageObject}->Time(
        Action => 'GET',
        Format => 'DateFormatLong',
    );

    # set text direction
    $Self->{TextDirection} = $Self->{LanguageObject}->{TextDirection};

    # check Frontend::Output::FilterElementPost
    $Self->{FilterElementPost} = {};

    my %FilterElementPost = %{ $ConfigObject->Get('Frontend::Output::FilterElementPost') // {} };

    FILTER:
    for my $Filter ( sort keys %FilterElementPost ) {

        # extract filter config
        my $FilterConfig = $FilterElementPost{$Filter};

        next FILTER if !$FilterConfig || ref $FilterConfig ne 'HASH';

        # extract template list
        my %TemplateList = %{ $FilterConfig->{Templates} || {} };

        if ( !%TemplateList || $TemplateList{ALL} ) {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => <<"EOF",
$FilterConfig->{Module} will be ignored because it wants to operate on all templates or does not specify a template list.
EOF
            );

            next FILTER;
        }

        $Self->{FilterElementPost}->{$Filter} = $FilterElementPost{$Filter};
    }

    # check Frontend::Output::FilterContent
    $Self->{FilterContent} = $ConfigObject->Get('Frontend::Output::FilterContent');

    # check Frontend::Output::FilterText
    $Self->{FilterText} = $ConfigObject->Get('Frontend::Output::FilterText');

    # check browser
    $Self->{Browser}         = 'Unknown';
    $Self->{BrowserVersion}  = 0;
    $Self->{Platform}        = '';
    $Self->{IsMobile}        = 0;
    $Self->{BrowserRichText} = 1;

    my $HttpUserAgent = lc( $ParamObject->Header('User-Agent') // '' );

    if ( !$HttpUserAgent ) {
        $Self->{Browser} = 'Unknown - no $ENV{"HTTP_USER_AGENT"}';
    }
    else {

        # check, if we are on a mobile platform.
        # tablets are handled like desktops
        # only phones are "mobile"
        if ( $HttpUserAgent =~ /mobile/ ) {
            $Self->{IsMobile} = 1;
        }

        # android
        if ( $HttpUserAgent =~ /android/ ) {
            $Self->{Platform} = 'Android';
        }

        # edge / spartan
        if ( $HttpUserAgent =~ /edge/ ) {
            $Self->{Browser} = 'Edge';
        }

        # msie
        elsif (
            $HttpUserAgent =~ /msie\s([0-9.]+)/
            || $HttpUserAgent =~ /internet\sexplorer\/([0-9.]+)/
            )
        {
            $Self->{Browser} = 'MSIE';

            if ( $1 =~ /(\d+)\.(\d+)/ ) {
                $Self->{BrowserMajorVersion} = $1;
                $Self->{BrowserMinorVersion} = $2;
            }

            # older windows mobile phones (until IE9), that still have 'MSIE' in the user agent string
            if ( $Self->{IsMobile} ) {
                $Self->{Platform} = 'Windows Phone';
            }
        }

        # mobile ie
        elsif ( $HttpUserAgent =~ /iemobile/ ) {
            $Self->{Browser}  = 'MSIE';
            $Self->{Platform} = 'Windows Phone';
        }

        # mobile ie (second try)
        elsif ( $HttpUserAgent =~ /trident/ ) {
            $Self->{Browser} = 'MSIE';

            if ( $HttpUserAgent =~ /rv:([0-9])+\.([0-9])+/ ) {
                $Self->{BrowserMajorVersion} = $2;
                $Self->{BrowserMinorVersion} = $3;
            }
        }

        # iOS
        elsif ( $HttpUserAgent =~ /(ipad|iphone|ipod)/ ) {
            $Self->{Platform} = 'iOS';
            $Self->{Browser}  = 'Safari';

            if ( $HttpUserAgent =~ /(ipad|iphone|ipod);.*cpu.*os ([0-9]+)_/ ) {
                $Self->{BrowserVersion} = $2;
            }

            if ( $HttpUserAgent =~ /crios/ ) {
                $Self->{Browser} = 'Chrome';
            }

            # RichText is supported in iOS6+.
            if ( $Self->{BrowserVersion} >= 6 ) {
                $Self->{BrowserRichText} = 1;
            }
            else {
                $Self->{BrowserRichText} = 0;
            }
        }

        # safari
        elsif ( $HttpUserAgent =~ /safari/ ) {

            # chrome
            if ( $HttpUserAgent =~ /chrome/ ) {
                $Self->{Browser} = 'Chrome';
            }
            else {
                $Self->{Browser} = 'Safari';
            }
        }

        # konqueror
        elsif ( $HttpUserAgent =~ /konqueror/ ) {
            $Self->{Browser} = 'Konqueror';

            # on konquerer disable rich text editor
            $Self->{BrowserRichText} = 0;
        }

        # firefox
        elsif ( $HttpUserAgent =~ /firefox/ ) {
            $Self->{Browser} = 'Firefox';
        }

        # opera
        elsif ( $HttpUserAgent =~ /^opera.*/ ) {
            $Self->{Browser} = 'Opera';
        }

        # netscape
        elsif ( $HttpUserAgent =~ /netscape/ ) {
            $Self->{Browser} = 'Netscape';
        }

        # w3m
        elsif ( $HttpUserAgent =~ /^w3m.*/ ) {
            $Self->{Browser}         = 'w3m';
            $Self->{BrowserRichText} = 0;       # as text browsers do not support JavaScript base rich text editors
        }

        # lynx
        elsif ( $HttpUserAgent =~ /^lynx.*/ ) {
            $Self->{Browser}         = 'Lynx';
            $Self->{BrowserRichText} = 0;        # as text browsers do not support JavaScript base rich text editors
        }

        # links
        elsif ( $HttpUserAgent =~ /^links.*/ ) {
            $Self->{Browser} = 'Links';
        }
        else {
            $Self->{Browser} = 'Unknown - ' . $HttpUserAgent;
        }
    }

    # check mobile devices to disable richtext support
    if (
        $Self->{IsMobile}
        && $Self->{Platform} ne 'iOS'
        && $Self->{Platform} ne 'Android'
        && $Self->{Platform} ne 'Windows Phone'
        )
    {
        $Self->{BrowserRichText} = 0;
    }

    # check if rich text can be active
    if ( !$Self->{BrowserRichText} ) {
        $ConfigObject->Set(
            Key   => 'Frontend::RichText',
            Value => 0,
        );
    }

    # check if rich text is active
    if ( !$ConfigObject->Get('Frontend::RichText') ) {
        $Self->{BrowserRichText} = 0;
    }

    # load theme
    my $Theme = $Self->{UserTheme} || $ConfigObject->Get('DefaultTheme') || Translatable('Standard');

    # force a theme based on host name
    my $DefaultThemeHostBased = $ConfigObject->Get('DefaultTheme::HostBased');
    my $Host                  = $ParamObject->Header('Host');
    if ( $DefaultThemeHostBased && $Host ) {

        THEME:
        for my $RegExp ( sort keys %{$DefaultThemeHostBased} ) {

            # do not use empty regexp or theme directories
            next THEME if !$RegExp;
            next THEME if $RegExp eq '';
            next THEME if !$DefaultThemeHostBased->{$RegExp};

            # check if regexp is matching
            if ( $Host =~ m/$RegExp/i ) {
                $Theme = $DefaultThemeHostBased->{$RegExp};
            }
        }
    }

    # locate template files
    $Self->{TemplateDir}         = $ConfigObject->Get('TemplateDir') . '/HTML/Templates/' . $Theme;
    $Self->{StandardTemplateDir} = $ConfigObject->Get('TemplateDir') . '/HTML/Templates/' . 'Standard';

    # Check if 'Standard' fallback exists
    if ( !-e $Self->{StandardTemplateDir} ) {
        $Self->FatalDie(
            Message =>
                "No existing template directory found ('$Self->{TemplateDir}')! Check your Home in Kernel/Config.pm."
        );
    }

    if ( !-e $Self->{TemplateDir} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  =>
                "No existing template directory found ('$Self->{TemplateDir}')!.
                Default theme used instead.",
        );

        # Set TemplateDir to 'Standard' as a fallback.
        $Theme = 'Standard';
        $Self->{TemplateDir} = $Self->{StandardTemplateDir};
    }

    $Self->{CustomTemplateDir}         = $ConfigObject->Get('CustomTemplateDir') . '/HTML/Templates/' . $Theme;
    $Self->{CustomStandardTemplateDir} = $ConfigObject->Get('CustomTemplateDir') . '/HTML/Templates/' . 'Standard';

    # get main object
    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    # load sub layout files
    my $NewDir = $ConfigObject->Get('TemplateDir') . '/HTML/Layout';
    if ( -e $NewDir ) {
        my @NewFiles = $MainObject->DirectoryRead(
            Directory => $NewDir,
            Filter    => '*.pm',
        );
        for my $NewFile (@NewFiles) {
            if ( $NewFile !~ /Layout.pm$/ ) {
                $NewFile =~ s{\A.*\/(.+?).pm\z}{$1}xms;
                my $NewClassName = "Kernel::Output::HTML::Layout::$NewFile";
                if ( !$MainObject->RequireBaseClass($NewClassName) ) {
                    $Self->FatalDie(
                        Message => "Could not load class Kernel::Output::HTML::Layout::$NewFile.",
                    );
                }
            }
        }
    }

    if ( $Self->{SessionID} && $Self->{UserChallengeToken} ) {
        $Self->{ChallengeTokenParam} = "ChallengeToken=$Self->{UserChallengeToken};";
    }

    # load NavigationModule if defined
    if ( $Self->{ModuleReg} ) {
        my $NavigationModule = $Kernel::OM->Get('Kernel::Config')->Get("Frontend::NavigationModule");
        if ( $NavigationModule->{ $Param{Action} } ) {
            $Self->{NavigationModule} = $NavigationModule->{ $Param{Action} };
        }
    }

    return $Self;
}

sub SetEnv {
    my ( $Self, %Param ) = @_;

    for (qw(Key Value)) {
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            $Self->FatalError();
        }
    }
    $Self->{EnvNewRef}->{ $Param{Key} } = $Param{Value};

    return 1;
}

=head2 Block()

call a block and pass data to it (optional) to generate the block's output.

    $LayoutObject->Block(
        Name => 'Row',
        Data => {
            Time => ...,
        },
    );

=cut

sub Block {
    my ( $Self, %Param ) = @_;

    if ( !$Param{Name} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Need Name!'
        );

        return;
    }

    # $Self->{BlockData} will be used in the subroutine Output()
    # which is provided by the base module Kernel::Output::HTML::Layout::Template
    $Self->{BlockData} //= [];
    push @{ $Self->{BlockData} },
        {
            Name => $Param{Name},
            Data => $Param{Data},
        };

    return 1;
}

=head2 JSONEncode()

Encode perl data structure to JSON string

    my $JSON = $LayoutObject->JSONEncode(
        Data        => $Data,
        NoQuotes    => 0|1, # optional: no double quotes at the start and the end of JSON string
    );

=cut

sub JSONEncode {
    my ( $Self, %Param ) = @_;

    # check for needed data
    return if !defined $Param{Data};

    # get JSON encoded data
    my $JSON = $Kernel::OM->Get('Kernel::System::JSON')->Encode(
        Data => $Param{Data},
    ) || '""';

    # remove leading and trailing double quotes if requested
    if ( $Param{NoQuotes} ) {
        $JSON =~ s{ \A "(.*)" \z }{$1}smx;
    }

    return $JSON;
}

=head2 Redirect()

throw a L<Kernel::System::Web::Exception> that triggers a redirect to the redirect URL

    # internal redirects
    $LayoutObject->Redirect(
        OP => "Action=AdminUserGroup;Subaction=User;ID=$UserID",
    );

    # external redirects
    $LayoutObject->Redirect(
        ExtURL => "http://some.example.com/",
    );

During login action, C<Login => 1> should be passed to Redirect().
This indicates that if the browser has cookie support, it is OK
for the session cookie to be not yet set.

=cut

sub Redirect {
    my ( $Self, %Param ) = @_;

    # Figure out to which URL should be redirected
    my $RedirectURL;
    if ( $Param{ExtURL} ) {
        $RedirectURL = $Param{ExtURL};
    }
    else {
        $RedirectURL = $Self->{Baselink};    # the fallback when there is no parameter OP

        if ( $Param{OP} ) {

            # Filter out hazardous characters
            if ( $Param{OP} =~ s{\x00}{}smxg ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => 'Someone tries to use a null bytes (\x00) character in redirect!',
                );
            }

            if ( $Param{OP} =~ s{\r}{}smxg ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => 'Someone tries to use a carriage return character in redirect!',
                );
            }

            if ( $Param{OP} =~ s{\n}{}smxg ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => 'Someone tries to use a newline character in redirect!',
                );
            }

            # internal redirect
            $Param{OP} =~ s/^.*\?(.+?)$/$1/;
            $RedirectURL .= $Param{OP};
        }

        # add session id to the redirect URL when appropriate
        if (
            !$Self->{SessionIDCookie}                             # there in no session cookie yet
            && !( $Self->{BrowserHasCookie} && $Param{Login} )    # not when cookie does not exits because we in Login
            && $RedirectURL !~ m/http/i                           # ???
            && $Self->{SessionID}                                 # when we actually have a session
            )
        {

            # TODO: think about using URI::query_form() for messing with the URL

            # look for the fragment part of the URL, the fragment part starts with an '#' and is always at the end of the URL
            my ( $Target, $Fragment );
            if ( $RedirectURL =~ m/^(.+?)#(|.+?)$/ ) {
                $Target   = $1;
                $Fragment = "#$2";
            }
            else {
                $Target   = $RedirectURL;
                $Fragment = '';
            }

            # find out how to correct inject the session id parameter, depending on the given target
            my $Joiner = eval {

                # either an empty query part or an empty final query param
                return '' if $Target =~ m/(\?|&)$/;

                # there is no query part yet
                return '?' if $Target !~ m/\?/;

                # add query param to existing query part
                return '&';
            };

            # add the fragment part of the URL again
            $RedirectURL = $Target . $Joiner . "$Self->{SessionName}=$Self->{SessionID}" . $Fragment;
        }
    }

    # create an response object we can work with
    my $RedirectResponse = Plack::Response->new();
    $RedirectResponse->redirect($RedirectURL);

    # Add the cookies that had been set in the constructor.
    # The values of $Self->{SetCookies} are plain hash references.
    # For some reason the name eventually used by Cookie::Baker::bake_cookie() is the attribute 'name' of the hashref.
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    if (
        $Self->{SetCookies}
        && ref $Self->{SetCookies} eq 'HASH'
        && $ConfigObject->Get('SessionUseCookie')
        )
    {
        for ( sort keys $Self->{SetCookies}->%* ) {

            # make a copy because we might need $Self->{SetCookies} later on
            my %Ingredients = $Self->{SetCookies}->{$_}->%*;
            my $Name        = delete $Ingredients{name};

            # the method 'cookies' is in lower case because we use Plack::Response directly
            $RedirectResponse->cookies->{$Name} = \%Ingredients;
        }
    }

    # The exception is caught be Plack::Middleware::HTTPExceptions
    die Kernel::System::Web::Exception->new(
        PlackResponse => $RedirectResponse
    );
}

sub Login {
    my ( $Self, %Param ) = @_;

    # set Action parameter for the loader
    $Self->{Action} = 'Login';
    $Param{IsLoginPage} = 1;

    # get singletons
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    if ( $ConfigObject->Get('SessionUseCookie') ) {

        # always set a cookie, so that at the time the user submits
        # the password, we know already if the browser supports cookies.
        # ( the session cookie isn't available at that time ).

        # Restrict Cookie to HTTPS if it is used.
        my $CookieSecureAttribute = $ConfigObject->Get('HttpType') eq 'https' ? 1 : undef;

        my $Expires = '+' . $ConfigObject->Get('SessionMaxTime') . 's';
        if ( !$ConfigObject->Get('SessionUseCookieAfterBrowserClose') ) {
            $Expires = '';
        }

        # set a cookie tentatively for checking cookie support
        $Self->SetCookie(
            Key      => 'OTOBOBrowserHasCookie',
            Value    => 1,
            Expires  => $Expires,
            Path     => $ConfigObject->Get('ScriptAlias'),
            Secure   => $CookieSecureAttribute,
            HttpOnly => 1,
        );
    }

    # get message of the day
    if ( $ConfigObject->Get('ShowMotd') ) {
        $Param{Motd} = $Self->Output(
            TemplateFile => 'Motd',
            Data         => \%Param
        );
    }

    # Generate the minified CSS and JavaScript files and the tags referencing them (see LayoutLoader)
    $Self->LoaderCreateAgentCSSCalls();
    $Self->LoaderCreateAgentJSCalls();
    $Self->LoaderCreateJavaScriptTranslationData();
    $Self->LoaderCreateJavaScriptTemplateData();

    # we need the baselink for VerfifiedGet() of selenium tests
    $Self->AddJSData(
        Key   => 'Baselink',
        Value => $Self->{Baselink},
    );

    # Add header logo, if configured
    if ( defined $ConfigObject->Get('AgentLogo') ) {
        my %AgentLogo = %{ $ConfigObject->Get('AgentLogo') };
        my %Data;

        for my $CSSStatement ( sort keys %AgentLogo ) {
            if ( $CSSStatement eq 'URL' ) {
                my $WebPath = '';
                if ( $AgentLogo{$CSSStatement} !~ /(http|ftp|https):\//i ) {
                    $WebPath = $ConfigObject->Get('Frontend::WebPath');
                }
                $Data{'URL'} = 'url(' . $WebPath . $AgentLogo{$CSSStatement} . ')';
            }
            else {
                $Data{$CSSStatement} = $AgentLogo{$CSSStatement};
            }
        }

        $Self->Block(
            Name => 'HeaderLogoCSS',
            Data => \%Data,
        );
    }

    # add login logo, if configured
    if ( defined $ConfigObject->Get('AgentLoginLogo') ) {
        my %AgentLoginLogo = %{ $ConfigObject->Get('AgentLoginLogo') };
        my %Data;

        for my $CSSStatement ( sort keys %AgentLoginLogo ) {
            if ( $CSSStatement eq 'URL' ) {
                my $WebPath = '';
                if ( $AgentLoginLogo{$CSSStatement} !~ /(http|ftp|https):\//i ) {
                    $WebPath = $ConfigObject->Get('Frontend::WebPath');
                }
                $Data{'URL'} = 'url(' . $WebPath . $AgentLoginLogo{$CSSStatement} . ')';
            }
            else {
                $Data{$CSSStatement} = $AgentLoginLogo{$CSSStatement};
            }
        }

        $Self->Block(
            Name => 'LoginLogoCSS',
            Data => \%Data,
        );

        $Self->Block(
            Name => 'LoginLogo'
        );
    }

    # get system maintenance object
    my $SystemMaintenanceObject = $Kernel::OM->Get('Kernel::System::SystemMaintenance');

    my $ActiveMaintenance = $SystemMaintenanceObject->SystemMaintenanceIsActive();

    # check if system maintenance is active
    if ($ActiveMaintenance) {
        my $SystemMaintenanceData = $SystemMaintenanceObject->SystemMaintenanceGet(
            ID     => $ActiveMaintenance,
            UserID => 1,
        );

        if ( $SystemMaintenanceData->{ShowLoginMessage} ) {

            my $LoginMessage =
                $SystemMaintenanceData->{LoginMessage}
                || $ConfigObject->Get('SystemMaintenance::IsActiveDefaultLoginMessage')
                || "System maintenance is active, not possible to perform a login!";

            $Self->Block(
                Name => 'SystemMaintenance',
                Data => {
                    LoginMessage => $LoginMessage,
                },
            );
        }
    }

    # show prelogin block, if in prelogin mode (e.g. SSO login)
    if ( defined $Param{'Mode'} && $Param{'Mode'} eq 'PreLogin' ) {
        $Self->Block(
            Name => 'PreLogin',
            Data => \%Param,
        );
    }

    # if not in PreLogin mode, show normal login form
    else {

        my $DisableLoginAutocomplete = $ConfigObject->Get('DisableLoginAutocomplete');
        $Param{UserNameAutocomplete} = $DisableLoginAutocomplete ? 'off' : 'username';
        $Param{PasswordAutocomplete} = $DisableLoginAutocomplete ? 'off' : 'current-password';

        $Self->Block(
            Name => 'LoginBox',
            Data => \%Param,
        );

        # show 2 factor password input if we have at least one backend enabled
        COUNT:
        for my $Count ( '', 1 .. 10 ) {
            next COUNT if !$ConfigObject->Get("AuthTwoFactorModule$Count");

            # if no empty shared secrets are allowed, input is mandatory
            my %MandatoryOptions;
            if ( !$ConfigObject->Get("AuthTwoFactorModule${Count}::AllowEmptySecret") ) {
                %MandatoryOptions = (
                    MandatoryClass   => 'Mandatory',
                    ValidateRequired => 'Validate_Required',
                );
            }

            $Self->Block(
                Name => 'AuthTwoFactor',
                Data => {
                    %Param,
                    %MandatoryOptions,
                },
            );

            if (%MandatoryOptions) {
                $Self->Block(
                    Name => 'AuthTwoFactorMandatory',
                    Data => \%Param,
                );
            }

            last COUNT;
        }

        # get lost password
        if (
            $ConfigObject->Get('LostPassword')
            && $ConfigObject->Get('AuthModule') eq 'Kernel::System::Auth::DB'
            )
        {
            $Self->Block(
                Name => 'LostPasswordLink',
                Data => \%Param,
            );

            $Self->Block(
                Name => 'LostPassword',
                Data => \%Param,
            );
        }
    }

    # send data to JS
    $Self->AddJSData(
        Key   => 'LoginFailed',
        Value => $Param{LoginFailed},
    );

    # declare headers including the X-OTOBO-Login header field
    $Self->_AddHeadersToResponseObject(
        XLoginHeader => 1,
    );

    # create & return output
    return $Self->Output(
        TemplateFile => 'Login',
        Data         => \%Param,
    );
}

sub ChallengeTokenCheck {
    my ( $Self, %Param ) = @_;

    # return if feature is disabled
    return 1 if !$Kernel::OM->Get('Kernel::Config')->Get('SessionCSRFProtection');

    # get challenge token and check it
    my $ChallengeToken = $Kernel::OM->Get('Kernel::System::Web::Request')->GetParam( Param => 'ChallengeToken' ) || '';

    # check regular ChallengeToken
    return 1 if $ChallengeToken eq $Self->{UserChallengeToken};

    # check ChallengeToken of all own sessions
    my $SessionObject = $Kernel::OM->Get('Kernel::System::AuthSession');
    my @Sessions      = $SessionObject->GetAllSessionIDs();

    SESSION:
    for my $SessionID (@Sessions) {
        my %Data = $SessionObject->GetSessionIDData( SessionID => $SessionID );
        next SESSION if !$Data{UserID};
        next SESSION if $Data{UserID} ne $Self->{UserID};
        next SESSION if !$Data{UserChallengeToken};

        # check ChallengeToken
        return 1 if $ChallengeToken eq $Data{UserChallengeToken};
    }

    # no valid token found
    if ( $Param{Type} && lc $Param{Type} eq 'customer' ) {
        $Self->CustomerFatalError(
            Message => 'Invalid Challenge Token!',
        );
    }
    else {
        $Self->FatalError(
            Message => 'Invalid Challenge Token!',
        );
    }

    return;
}

sub FatalError {
    my ( $Self, %Param ) = @_;

    # Prevent endless recursion in case of problems with Template engine.
    return if $Self->{InFatalError}++;

    if ( $Param{Message} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Caller   => 1,
            Priority => 'error',
            Message  => $Param{Message},
        );
    }

    my $Output = join '',
        $Self->Header(
            Area  => 'Frontend',
            Title => 'Fatal Error'
        ),
        $Self->Error(%Param),
        $Self->Footer();

    # Modify the output by applying the output filters.
    $Output = $Self->ApplyOutputFilters( Output => $Output );

    # The Content-Length will be set later in the middleware Plack::Middleware::ContentLength. This requires that
    # there are no multi-byte characters in the delivered content. This is because the middleware
    # uses core::length() for determining the content length.
    $Kernel::OM->Get('Kernel::System::Encode')->EncodeOutput( \$Output );

    # The OTOBO response object already has the HTPP headers.
    # Enhance it with the HTTP status code and the content.
    my $ErrorResponse = Plack::Response->new(
        200,
        $Kernel::OM->Get('Kernel::System::Web::Response')->Headers(),
        $Output
    );

    # The exception is caught be Plack::Middleware::HTTPExceptions
    die Kernel::System::Web::Exception->new(
        PlackResponse => $ErrorResponse
    );
}

sub SecureMode {
    my ( $Self, %Param ) = @_;

    return join '',
        $Self->Header(
            Area  => 'Frontend',
            Title => 'Secure Mode'
        ),
        $Self->Output(
            TemplateFile => 'AdminSecureMode',
            Data         => \%Param
        ),
        $Self->Footer();
}

sub FatalDie {
    my ( $Self, %Param ) = @_;

    if ( $Param{Message} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Caller   => 1,
            Priority => 'error',
            Message  => $Param{Message},
        );
    }

    # get backend error messages
    for (qw(Message Traceback)) {
        my $Backend = 'Backend' . $_;
        $Param{$Backend} = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
            Type => 'Error',
            What => $_
        ) || '';
        $Param{$Backend} = $Self->Ascii2Html(
            Text           => $Param{$Backend},
            HTMLResultMode => 1,
        );
    }
    if ( !$Param{Message} ) {
        $Param{Message} = $Param{BackendMessage};
    }

    # Strings are not caught by Plack::Middleware::HTTPExceptions
    die $Param{Message};
}

sub ErrorScreen {
    my ( $Self, %Param ) = @_;

    return join '',
        $Self->Header( Title => 'Error' ),
        $Self->Error(%Param),
        $Self->Footer();
}

sub Error {
    my ( $Self, %Param ) = @_;

    # get backend error messages
    for (qw(Message Traceback)) {
        my $Backend = 'Backend' . $_;
        $Param{$Backend} = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
            Type => 'Error',
            What => $_
        ) || '';
    }
    if ( !$Param{BackendMessage} && !$Param{BackendTraceback} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => $Param{Message} || '?',
        );
        for (qw(Message Traceback)) {
            my $Backend = 'Backend' . $_;
            $Param{$Backend} = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
                Type => 'Error',
                What => $_
            ) || '';
        }
    }

    if ( !$Param{Message} ) {
        $Param{Message} = $Param{BackendMessage};
    }

    if ( $Param{BackendTraceback} ) {
        $Self->Block(
            Name => 'ShowBackendTraceback',
            Data => \%Param,
        );
    }

    # create & return output
    return $Self->Output(
        TemplateFile => 'Error',
        Data         => \%Param
    );
}

sub Warning {
    my ( $Self, %Param ) = @_;

    # get backend error messages
    $Param{BackendMessage} = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
        Type => 'Notice',
        What => 'Message',
        )
        || $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
            Type => 'Error',
            What => 'Message',
        ) || '';

    if ( !$Param{Message} ) {
        $Param{Message} = $Param{BackendMessage};
    }

    # create & return output
    return $Self->Output(
        TemplateFile => 'Warning',
        Data         => \%Param
    );
}

=head2 Notify()

create notify lines

    infos, the text will be translated

    my $Output = $LayoutObject->Notify(
        Priority => 'Warning',
        Info => 'Some Info Message',
    );

    data with link, the text will be translated

    my $Output = $LayoutObject->Notify(
        Priority  => 'Warning',
        Data      => 'Template content',
        Link      => 'http://example.com/',
        LinkClass => 'some_CSS_class',              # optional
    );

    errors, the text will be translated

    my $Output = $LayoutObject->Notify(
        Priority => 'Error',
        Info => 'Some Error Message',
    );

    errors from log backend, if no error exists, a '' will be returned

    my $Output = $LayoutObject->Notify(
        Priority => 'Error',
    );

=cut

sub Notify {
    my ( $Self, %Param ) = @_;

    # create & return output
    if ( !$Param{Info} && !$Param{Data} ) {
        $Param{BackendMessage} = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
            Type => 'Notice',
            What => 'Message',
            )
            || $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
                Type => 'Error',
                What => 'Message',
            ) || '';

        $Param{Info} = $Param{BackendMessage};

        # return if we have nothing to show
        return '' if !$Param{Info};
    }

    my $BoxClass = 'Notice';

    if ( $Param{Info} ) {
        $Param{Info} =~ s/\n//g;
    }
    if ( $Param{Priority} && $Param{Priority} eq 'Error' ) {
        $BoxClass = 'Error';
    }
    elsif ( $Param{Priority} && $Param{Priority} eq 'Success' ) {
        $BoxClass = 'Success';
    }
    elsif ( $Param{Priority} && $Param{Priority} eq 'Info' ) {
        $BoxClass = 'Info';
    }

    if ( $Param{Link} ) {
        $Self->Block(
            Name => 'LinkStart',
            Data => {
                LinkStart => $Param{Link},
                LinkClass => $Param{LinkClass} || '',
            },
        );
    }
    if ( $Param{Data} ) {
        $Self->Block(
            Name => 'Data',
            Data => \%Param,
        );
    }
    else {
        $Self->Block(
            Name => 'Text',
            Data => \%Param,
        );
    }
    if ( $Param{Link} ) {
        $Self->Block(
            Name => 'LinkStop',
            Data => {
                LinkStop => '</a>',
            },
        );
    }
    return $Self->Output(
        TemplateFile => 'Notify',
        Data         => {
            %Param,
            BoxClass => $BoxClass,
        },
    );
}

=head2 NotifyNonUpdatedTickets()

Adds notification about tickets which are not updated.

    my $Output = $LayoutObject->NotifyNonUpdatedTickets();

=cut

sub NotifyNonUpdatedTickets {
    my ( $Self, %Param ) = @_;

    my $NonUpdatedTicketsString = $Kernel::OM->Get('Kernel::System::Cache')->Get(
        Type => 'Ticket',
        Key  => 'NonUpdatedTicketsString-' . $Self->{UserID},
    );

    return if !$NonUpdatedTicketsString;

    # Delete this value from the cache.
    $Kernel::OM->Get('Kernel::System::Cache')->Delete(
        Type => 'Ticket',
        Key  => 'NonUpdatedTicketsString-' . $Self->{UserID},
    );

    return $Self->Notify(
        Info => $Self->{LanguageObject}->Translate( "The following tickets are not updated: %s.", $NonUpdatedTicketsString ),
    );

}

=head2 Header()

generates the HTML for the page begin in the Agent interface.
As a side effect HTTP headers are added to the Kernel::System::Web::Response object.

    my $Output = $LayoutObject->Header(
        Type                          => 'Small',   # (optional) '' (Default, full header) or 'Small' (blank header)
        ShowToolbarItems              => 0,         # (optional) default 1 (0|1)
        ShowPrefLink                  => 0,         # (optional) default 1 (0|1)
        ShowLogoutButton              => 0,         # (optional) default 1 (0|1)
        DisableIFrameOriginRestricted => 1,         # (optional, default 0) - suppress X-Frame-Options header.
    );

=cut

sub Header {
    my ( $Self, %Param ) = @_;

    # extract params
    my $Type = $Param{Type} || '';

    # check params
    $Param{ShowToolbarItems} //= 1;
    $Param{ShowPrefLink}     //= 1;
    $Param{ShowLogoutButton} //= 1;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # do not show preferences link if the preferences module is disabled
    my $Modules = $ConfigObject->Get('Frontend::Module');
    if ( !$Modules->{AgentPreferences} ) {
        $Param{ShowPrefLink} = 0;
    }

    # set rtl if needed
    if ( $Self->{TextDirection} && $Self->{TextDirection} eq 'rtl' ) {
        $Param{BodyClass} = 'RTL';
    }
    elsif ( $ConfigObject->Get('Frontend::DebugMode') ) {
        $Self->Block(
            Name => 'DebugRTLButton',
        );
    }

    # Generate the minified CSS and JavaScript files and the tags referencing them (see LayoutLoader)
    $Self->LoaderCreateAgentCSSCalls();

    my %AgentLogo;

    # check if we need to display a custom logo for the selected skin
    my $AgentLogoCustom = $ConfigObject->Get('AgentLogoCustom');
    if (
        $Self->{SkinSelected}
        && $AgentLogoCustom
        && IsHashRefWithData($AgentLogoCustom)
        && $AgentLogoCustom->{ $Self->{SkinSelected} }
        )
    {
        %AgentLogo = %{ $AgentLogoCustom->{ $Self->{SkinSelected} } };
    }

    # Otherwise show default header logo, if configured
    elsif ( defined $ConfigObject->Get('AgentLogo') ) {
        %AgentLogo = %{ $ConfigObject->Get('AgentLogo') };
    }

    if ( %AgentLogo && keys %AgentLogo ) {

        my %Data;
        for my $CSSStatement ( sort keys %AgentLogo ) {
            if ( $CSSStatement eq 'URL' ) {
                my $WebPath = '';
                if ( $AgentLogo{$CSSStatement} !~ /(http|ftp|https):\//i ) {
                    $WebPath = $ConfigObject->Get('Frontend::WebPath');
                }
                $Data{'URL'} = 'url(' . $WebPath . $AgentLogo{$CSSStatement} . ')';
            }
            else {
                $Data{$CSSStatement} = $AgentLogo{$CSSStatement};
            }
        }

        $Self->Block(
            Name => 'HeaderLogoCSS',
            Data => \%Data,
        );
    }

    my $File = $Param{Filename} || $Self->{Action} || 'unknown';

    # set file name for "save page as"
    $Param{ContentDisposition} = "filename=\"$File.html\"";

    # area and title
    if ( !$Param{Area} ) {
        $Param{Area} = (
            defined $Self->{Action}
            ? $ConfigObject->Get('Frontend::Module')->{ $Self->{Action} }->{NavBarName}
            : ''
        );
    }
    if ( !$Param{Title} ) {
        $Param{Title} = $ConfigObject->Get('Frontend::Module')->{ $Self->{Action} }->{Title}
            || '';
    }
    for my $Word (qw(Value Title Area)) {
        if ( $Param{$Word} ) {
            $Param{TitleArea} .= $Self->{LanguageObject}->Translate( $Param{$Word} ) . ' - ';
        }
    }

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    # run header meta modules
    my $HeaderMetaModule = $ConfigObject->Get('Frontend::HeaderMetaModule');
    if ( ref $HeaderMetaModule eq 'HASH' ) {
        my %Jobs = %{$HeaderMetaModule};

        MODULE:
        for my $Job ( sort keys %Jobs ) {

            # load and run module
            next MODULE if !$MainObject->Require( $Jobs{$Job}->{Module} );
            my $Object = $Jobs{$Job}->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
            );
            next MODULE if !$Object;
            $Object->Run( %Param, Config => $Jobs{$Job} );
        }
    }

    # run tool bar item modules
    if ( $Self->{UserID} && ( $Self->{UserType} // '' ) eq 'User' ) {
        my $ToolBarModule = $ConfigObject->Get('Frontend::ToolBarModule');
        if ( $Param{ShowToolbarItems} && ref $ToolBarModule eq 'HASH' ) {

            $Self->Block(
                Name => 'ToolBar',
                Data => \%Param,
            );

            my %Modules;
            my %Jobs = %{$ToolBarModule};

            # get group object
            my $GroupObject = $Kernel::OM->Get('Kernel::System::Group');

            MODULE:
            for my $Job ( sort keys %Jobs ) {

                # load and run module
                next MODULE if !$MainObject->Require( $Jobs{$Job}->{Module} );
                my $Object = $Jobs{$Job}->{Module}->new(
                    %{$Self},    # UserID etc.
                );
                next MODULE if !$Object;

                my $ToolBarAccessOk;

                # if group restriction for tool-bar is set, check user permission
                if ( $Jobs{$Job}->{Group} ) {

                    # remove white-spaces
                    $Jobs{$Job}->{Group} =~ s{\s}{}xmsg;

                    # get group configurations
                    my @Items = split /;/, $Jobs{$Job}->{Group};

                    ITEM:
                    for my $Item (@Items) {

                        # split values into permission and group
                        my ( $Permission, $GroupName ) = split /:/, $Item;

                        # log an error if not valid setting
                        if ( !$Permission || !$GroupName ) {
                            $Kernel::OM->Get('Kernel::System::Log')->Log(
                                Priority => 'error',
                                Message  => "Invalid config for ToolBarModule $Job - Key Group: '$Item'! "
                                    . "Need something like 'Permission:Group;'",
                            );
                        }

                        # get groups for current user
                        my %Groups = $GroupObject->PermissionUserGet(
                            UserID => $Self->{UserID},
                            Type   => $Permission,
                        );

                        # next job if user have not groups
                        next ITEM if !%Groups;

                        # check user belongs to the correct group
                        my %GroupsReverse = reverse %Groups;
                        next ITEM if !$GroupsReverse{$GroupName};

                        $ToolBarAccessOk = 1;

                        last ITEM;
                    }

                    # go to the next module if not permissions
                    # for the current one
                    next MODULE if !$ToolBarAccessOk;
                }

                %Modules = ( $Object->Run( %Param, Config => $Jobs{$Job} ), %Modules );
            }

            # Rother OSS TODO: Not so nice implemented, review

            my $ToolBarItemSeparatorShortcut  = 0;
            my $ToolBarItemSeparatorMyTickets = 0;
            my $ToolBarItemSeparatorSearch    = 0;

            # Check which seperator is needed
            SHORTCUTAVAILIBLE:
            for my $Key ( sort keys %Modules ) {
                next SHORTCUTAVAILIBLE if !%{ $Modules{$Key} };

                if ( $Modules{$Key}{Block} eq 'ToolBarItem' ) {
                    $ToolBarItemSeparatorMyTickets = 1;
                    next SHORTCUTAVAILIBLE;
                }
                elsif ( $Modules{$Key}{Block} eq 'ToolBarItemShortcut' ) {
                    $ToolBarItemSeparatorShortcut = 1;
                    next SHORTCUTAVAILIBLE;
                }
                elsif ( $Modules{$Key}{Block} =~ m/ToolBarSearch.*/ ) {
                    $ToolBarItemSeparatorSearch = 1;
                    next SHORTCUTAVAILIBLE;
                }
            }

            # Show separator between shortcuts and my tickets
            if ( $ToolBarItemSeparatorShortcut == 1 ) {
                $Self->Block(
                    Name => "ToolBarItemSeparatorShortcut",
                );
            }

            # show tool bar shortcut items
            MODULESHORTCUT:
            for my $Key ( sort keys %Modules ) {
                next MODULESHORTCUT if !%{ $Modules{$Key} };
                next MODULESHORTCUT if $Modules{$Key}{Block} ne 'ToolBarItemShortcut';

                $Self->Block(
                    Name => $Modules{$Key}->{Block},
                    Data => {
                        %{ $Modules{$Key} },
                        AccessKeyReference => $Modules{$Key}->{AccessKey}
                        ? " ($Modules{$Key}->{AccessKey})"
                        : '',
                    },
                );
            }

            # Check if shortcut needed
            if ( $ToolBarItemSeparatorMyTickets == 1 ) {

                # Show separator between shortcuts and my tickets
                $Self->Block(
                    Name => "ToolBarItemSeparatorMyTickets",
                );
            }

            # show tool bar items
            MODULE:
            for my $Key ( sort keys %Modules ) {
                next MODULE if !%{ $Modules{$Key} };
                next MODULE if $Modules{$Key}{Block} eq 'ToolBarItemShortcut';

                # For ToolBarSearchFulltext module take into consideration SearchInArchive settings.
                # See bug#13790 (https://bugs.otrs.org/show_bug.cgi?id=13790).
                if ( $ConfigObject->Get('Ticket::ArchiveSystem') && $Modules{$Key}->{Block} eq 'ToolBarSearchFulltext' )
                {
                    $Modules{$Key}->{SearchInArchive} = $ConfigObject->Get('Ticket::Frontend::AgentTicketSearch')->{Defaults}->{SearchInArchive};
                }

                $Self->Block(
                    Name => $Modules{$Key}->{Block},
                    Data => {
                        %{ $Modules{$Key} },
                        AccessKeyReference => $Modules{$Key}->{AccessKey}
                        ? " ($Modules{$Key}->{AccessKey})"
                        : '',
                    },
                );
            }

            # Check if shortcut needed
            if ( $ToolBarItemSeparatorSearch == 1 ) {

                # Show separator between shortcuts and my tickets
                $Self->Block(
                    Name => "ToolBarItemSeparatorSearch",
                );
            }
        }

        if ( $Kernel::OM->Get('Kernel::System::Main')->Require( 'Kernel::System::Chat', Silent => 1 ) ) {
            if ( $ConfigObject->Get('ChatEngine::Active') ) {
                $Self->AddJSData(
                    Key   => 'ChatEngine::Active',
                    Value => $ConfigObject->Get('ChatEngine::Active')
                );
            }
        }

        # generate avatar
        if ( $ConfigObject->Get('Frontend::AvatarEngine') eq 'Gravatar' && $Self->{UserEmail} ) {
            my $DefaultIcon = $ConfigObject->Get('Frontend::Gravatar::DefaultImage') || 'mp';
            $Kernel::OM->Get('Kernel::System::Encode')->EncodeOutput( \$Self->{UserEmail} );
            $Param{Avatar} = '//www.gravatar.com/avatar/' . md5_hex( lc $Self->{UserEmail} ) . '?s=100&d=' . $DefaultIcon;
        }
        else {
            my %User = $Kernel::OM->Get('Kernel::System::User')->GetUserData(
                User          => $Self->{UserLogin},
                NoOutOfOffice => 1,
            );

            $Param{UserInitials} = $Self->UserInitialsGet( Fullname => $User{UserFullname} );
        }

        # show logged in notice
        if ( $Param{ShowPrefLink} ) {
            $Self->Block(
                Name => 'Login',
                Data => \%Param,
            );
        }
        else {
            $Self->Block(
                Name => 'LoginWithoutLink',
                Data => \%Param,
            );
        }

        # show logout button (if registered)
        if (
            $Param{ShowLogoutButton}
            && $ConfigObject->Get('Frontend::Module')->{Logout}
            )
        {
            $Self->Block(
                Name => 'Logout',
                Data => \%Param,
            );
        }
    }

    $Self->_AddHeadersToResponseObject(
        ContentDisposition            => $Param{ContentDisposition},
        DisableIFrameOriginRestricted => $Param{DisableIFrameOriginRestricted},
    );

    # create & return output
    return $Self->Output(
        TemplateFile => "Header$Type",
        Data         => \%Param
    );
}

=begin Internal:

=head2 _AddHeadersToResponseObject()

basically the same thing as executing the formerly used template HTTPHeaders.tt

    my $Success = $LayoutObject->_AddHeadersToResponseObject(
        Data => \%Params,
    );

The cookies are also added here.
The previously set headers are discarded.

=cut

sub _AddHeadersToResponseObject {
    my ( $Self, %Param ) = @_;

    # there are no required parameters

    # first the unconditional headers
    my %Headers = (
        'Content-Type'  => 'text/html; charset=utf-8',
        'Expires'       => 'Tue, 1 Jan 1980 12:00:00 GMT',
        'Cache-Control' => 'no-cache',
        'Pragma'        => 'no-cache',
    );

    if ( $Param{ContentDisposition} ) {
        $Headers{'Content-Disposition'} = $Param{ContentDisposition};
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    if ( !$ConfigObject->Get('Secure::DisableBanner') ) {
        $Headers{'X-Powered-By'} = join ' ', $ConfigObject->Get('Product'), $ConfigObject->Get('Version'), '(https://www.otobo.de/)';
    }

    if (
        !$ConfigObject->Get('DisableIFrameOriginRestricted')
        && !$Param{DisableIFrameOriginRestricted}
        )
    {
        $Headers{'X-Frame-Options'} = 'SAMEORIGIN';
    }

    # With this X-Header, Core.AJAX can recognize that the AJAX request returned the login page (session timeout) and perform a redirect.
    if ( $Param{XLoginHeader} ) {
        $Headers{'X-OTOBO-Login'} = $Self->{Baselink};
    }

    my $ResponseObject = $Kernel::OM->Get('Kernel::System::Web::Response');
    $ResponseObject->Headers( [%Headers] );

    # Add the cookies that had been set in the constructor.
    # The values of $Self->{SetCookies} are plain hash references.
    # For some reason the name eventually used by Cookie::Baker::bake_cookie() is the attribute 'name' of the hashref.
    if (
        $Self->{SetCookies}
        && ref $Self->{SetCookies} eq 'HASH'
        && $ConfigObject->Get('SessionUseCookie')
        )
    {
        for ( sort keys $Self->{SetCookies}->%* ) {

            # make a copy because we might need $Self->{SetCookies} later on
            my %Ingredients = $Self->{SetCookies}->{$_}->%*;
            my $Name        = delete $Ingredients{name};
            $ResponseObject->Cookies->{$Name} = \%Ingredients;
        }
    }

    return 1;
}

=end Internal:

=head2 Footer()

generates the HTML for the page end in the Agent interface.

    my $Output = $LayoutObject->Footer();

=cut

sub Footer {
    my ( $Self, %Param ) = @_;

    my $Type          = $Param{Type}           || '';
    my $HasDatepicker = $Self->{HasDatepicker} || 0;

    # generate the minified CSS and JavaScript files and the tags referencing them (see LayoutLoader)
    $Self->LoaderCreateAgentJSCalls();
    $Self->LoaderCreateJavaScriptTranslationData();
    $Self->LoaderCreateJavaScriptTemplateData();

    # get datepicker data, if needed in module
    if ($HasDatepicker) {
        my $VacationDays  = $Self->DatepickerGetVacationDays();
        my $TextDirection = $Self->{LanguageObject}->{TextDirection} || '';

        # send data to JS
        $Self->AddJSData(
            Key   => 'Datepicker',
            Value => {
                VacationDays => $VacationDays,
                IsRTL        => ( $TextDirection eq 'rtl' ) ? 1 : 0,
            },
        );
    }

    # get config object
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # send data to JS if NewTicketInNewWindow is enabled
    if ( $ConfigObject->Get('NewTicketInNewWindow::Enabled') ) {
        $Self->AddJSData(
            Key   => 'NewTicketInNewWindow',
            Value => 1,
        );
    }

    # AutoComplete-Config
    my $AutocompleteConfig = $ConfigObject->Get('AutoComplete::Agent');

    for my $ConfigElement ( sort keys %{$AutocompleteConfig} ) {
        $AutocompleteConfig->{$ConfigElement}->{ButtonText}
            = $Self->{LanguageObject}->Translate( $AutocompleteConfig->{$ConfigElement}->{ButtonText} );
    }

    # Search frontend (JavaScript)
    my $SearchFrontendConfig = $ConfigObject->Get('Frontend::Search::JavaScript');

    # get target javascript function
    my $JSCall = '';

    if ( $SearchFrontendConfig && $Self->{Action} ) {
        for my $Group ( sort keys %{$SearchFrontendConfig} ) {
            REGEXP:
            for my $RegExp ( sort keys %{ $SearchFrontendConfig->{$Group} } ) {
                if ( $Self->{Action} =~ /$RegExp/ ) {
                    $JSCall = $SearchFrontendConfig->{$Group}->{$RegExp};
                    last REGEXP;
                }
            }
        }
    }

    # Check if video chat is enabled.
    if ( $Kernel::OM->Get('Kernel::System::Main')->Require( 'Kernel::System::VideoChat', Silent => 1 ) ) {
        $Param{VideoChatEnabled} = $Kernel::OM->Get('Kernel::System::VideoChat')->IsEnabled()
            || $Kernel::OM->Get('Kernel::System::Web::Request')->GetParam( Param => 'UnitTestMode' ) // 0;
    }

    # Set an array with pending states. Skip for installer and migration script.
    my @PendingStateIDs = $ConfigObject->Get('SecureMode')
        ? $Kernel::OM->Get('Kernel::System::State')->StateGetStatesByType(
            StateType => [ 'pending reminder', 'pending auto' ],
            Result    => 'ID',
        )
        : ();

    # add JS data
    my %JSConfig = (
        Baselink                       => $Self->{Baselink},
        CGIHandle                      => $Self->{CGIHandle},
        WebPath                        => $ConfigObject->Get('Frontend::WebPath'),
        Action                         => $Self->{Action},
        Subaction                      => $Self->{Subaction},
        SessionIDCookie                => $Self->{SessionIDCookie},
        SessionName                    => $Self->{SessionName},
        SessionID                      => $Self->{SessionID},
        SessionUseCookie               => $ConfigObject->Get('SessionUseCookie'),
        ChallengeToken                 => $Self->{UserChallengeToken},
        CustomerPanelSessionName       => $ConfigObject->Get('CustomerPanelSessionName'),
        UserLanguage                   => $Self->{UserLanguage},
        WebMaxFileUpload               => $ConfigObject->Get('WebMaxFileUpload'),
        RichTextSet                    => $ConfigObject->Get('Frontend::RichText'),
        CheckEmailAddresses            => $ConfigObject->Get('CheckEmailAddresses'),
        MenuDragDropEnabled            => $ConfigObject->Get('Frontend::MenuDragDropEnabled'),
        OpenMainMenuOnHover            => $ConfigObject->Get('OpenMainMenuOnHover'),
        CustomerInfoSet                => $ConfigObject->Get('Ticket::Frontend::CustomerInfoCompose'),
        IncludeUnknownTicketCustomers  => $ConfigObject->Get('Ticket::IncludeUnknownTicketCustomers'),
        InputFieldsActivated           => $ConfigObject->Get('ModernizeFormFields'),
        VideoChatEnabled               => $Param{VideoChatEnabled},
        PendingStateIDs                => \@PendingStateIDs,
        CheckSearchStringsForStopWords => (
            $ConfigObject->Get('Ticket::SearchIndex::WarnOnStopWordUsage')
                &&
                (
                    $ConfigObject->Get('Ticket::SearchIndexModule')
                    eq 'Kernel::System::Ticket::ArticleSearchIndex::DB'
                )
        ) ? 1 : 0,
        SearchFrontend => $JSCall,
        Autocomplete   => $AutocompleteConfig,
    );

    for my $Config ( sort keys %JSConfig ) {
        $Self->AddJSData(
            Key   => $Config,
            Value => $JSConfig{$Config},
        );
    }

    # create & return output
    return $Self->Output(
        TemplateFile => "Footer$Type",
        Data         => \%Param
    );
}

sub ApplyOutputFilters {
    my ( $Self, %Param ) = @_;

    # The param Output may be anything that may be passed to Plack::Response::body().
    my $Output = $Param{Output};

    # Return early when there is nothing to do.
    # This should be cheap, as Perl has copy on write.
    return $Output unless $Self->{FilterContent};
    return $Output unless ref $Self->{FilterContent} eq 'HASH';

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    # apply the filters, explicitly track whether there actually was a modification
    my %FilterList = $Self->{FilterContent}->%*;
    my ( $NumAppliedFilters, $ModifiedOutput ) = ( 0, '' );
    FILTER:
    for my $Filter ( sort keys %FilterList ) {

        # extract filter config
        my $FilterConfig = $FilterList{$Filter};

        next FILTER unless $FilterConfig;
        next FILTER unless ref $FilterConfig eq 'HASH';

        # extract template list
        my $TemplateList = $FilterConfig->{Templates};

        # check template list
        if ( !$TemplateList || ref $TemplateList ne 'HASH' || !$TemplateList->%* ) {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  =>
                    "Please add a template list to output filter $FilterConfig->{Module} "
                    . "to improve performance. Use ALL if OutputFilter should modify all "
                    . "templates of the system (deprecated).",
            );
        }

        # check template list
        if ( $Param{TemplateFile} && ref $TemplateList eq 'HASH' && !$TemplateList->{ALL} ) {
            next FILTER unless $TemplateList->{ $Param{TemplateFile} };
        }

        next FILTER unless $MainObject->Require( $FilterConfig->{Module} );

        # create new instance
        my $Object = $FilterConfig->{Module}->new(
            %{$Self},
            LayoutObject => $Self,
        );

        next FILTER unless $Object;

        # The output filters operate on strings.
        # Lazily generate the string only when it is needed for the first filter.
        if ( !$NumAppliedFilters ) {

            # Using Plack::Util::foreach() in order to cover all cases, e.g. when $Output is a file handle.
            # The logic is inspired by Plack::Response::_body().
            my $PSGIBody;
            if ( !ref $Output ) {
                $PSGIBody = [$Output];
            }
            elsif ( blessed($Output) && overload::Method( $Output, q("") ) && !$Output->can('getline') ) {
                $PSGIBody = [$Output];
            }
            else {
                $PSGIBody = $Output;
            }

            Plack::Util::foreach(
                $PSGIBody,
                sub {
                    my ($Line) = @_;

                    $ModifiedOutput .= $Line;

                    return;
                }
            );
        }

        # run output filter
        $Object->Run(
            %{$FilterConfig},
            Data         => \$ModifiedOutput,
            TemplateFile => $Param{TemplateFile} || '',
        );

        $NumAppliedFilters++;
    }

    # return the original output when no filters ran
    return $NumAppliedFilters ? $ModifiedOutput : $Output;
}

=head2 Ascii2Html()

convert ASCII to html string

    my $HTML = $LayoutObject->Ascii2Html(
        Text            => 'Some <> Test <font color="red">Test</font>',
        Max             => 20,       # max 20 chars flowed by [..]
        VMax            => 15,       # first 15 lines
        NewLine         => 0,        # move \r to \n
        HTMLResultMode  => 0,        # replace " " with C<&nbsp;>
        StripEmptyLines => 0,
        Type            => 'Normal', # JSText or Normal text
        LinkFeature     => 0,        # do some URL detections
    );

also string ref is possible

    my $HTMLStringRef = $LayoutObject->Ascii2Html(
        Text => \$String,
    );

=cut

sub Ascii2Html {
    my ( $Self, %Param ) = @_;

    # check needed param
    return '' if !defined $Param{Text};

    # check text
    my $TextScalar;
    my $Text;
    if ( !ref $Param{Text} ) {
        $TextScalar = 1;
        $Text       = \$Param{Text};
    }
    elsif ( ref $Param{Text} eq 'SCALAR' ) {
        $Text = $Param{Text};
    }
    else {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Invalid ref "' . ref( $Param{Text} ) . '" of Text param!',
        );
        return '';
    }

    # run output filter text
    my @Filters;
    if ( $Param{LinkFeature} && $Self->{FilterText} && ref $Self->{FilterText} eq 'HASH' ) {

        # extract filter list
        my %FilterList = %{ $Self->{FilterText} };

        my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

        FILTER:
        for my $Filter ( sort keys %FilterList ) {

            # extract filter config
            my $FilterConfig = $FilterList{$Filter};

            next FILTER if !$FilterConfig;
            next FILTER if ref $FilterConfig ne 'HASH';

            # extract template list
            my $TemplateList = $FilterConfig->{Templates};

            # check template list
            if ( !$TemplateList || ref $TemplateList ne 'HASH' || !%{$TemplateList} ) {

                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  =>
                        "Please add a template list to output filter $FilterConfig->{Module} "
                        . "to improve performance. Use ALL if OutputFilter should modify all "
                        . "templates of the system (deprecated).",
                );
            }

            # check template list
            if ( $Param{TemplateFile} && ref $TemplateList eq 'HASH' && !$TemplateList->{ALL} ) {
                next FILTER if !$TemplateList->{ $Param{TemplateFile} };
            }

            $Self->FatalDie() if !$MainObject->Require( $FilterConfig->{Module} );

            # create new instance
            my $Object = $FilterConfig->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
            );

            next FILTER if !$Object;

            push(
                @Filters,
                {
                    Object => $Object,
                    Filter => $FilterConfig,
                },
            );
        }

        # pre run
        for my $Filter (@Filters) {

            $Text = $Filter->{Object}->Pre(
                Filter => $Filter->{Filter},
                Data   => $Text,
            );
        }
    }

    # max width
    if ( $Param{Max} && length ${$Text} > $Param{Max} ) {
        ${$Text} = substr( ${$Text}, 0, $Param{Max} - 5 ) . '[...]';
    }

    # newline
    if ( $Param{NewLine} && length( ${$Text} ) < 140_000 ) {
        ${$Text} =~ s/(\n\r|\r\r\n|\r\n)/\n/g;
        ${$Text} =~ s/\r/\n/g;
        ${$Text} =~ s/(.{4,$Param{NewLine}})(?:\s|\z)/$1\n/gm;
    }

    # remove tabs
    ${$Text} =~ s/\t/ /g;

    # strip empty lines
    if ( $Param{StripEmptyLines} ) {
        ${$Text} =~ s/^\s*\n//mg;
    }

    # max lines
    if ( $Param{VMax} ) {
        my @TextList = split /\n/, ${$Text};
        ${$Text} = '';
        my $Counter = 1;
        for (@TextList) {
            if ( $Counter <= $Param{VMax} ) {
                ${$Text} .= $_ . "\n";
            }
            $Counter++;
        }
        if ( $Counter >= $Param{VMax} ) {
            ${$Text} .= "[...]\n";
        }
    }

    # html quoting
    ${$Text} =~ s/&/&amp;/g;
    ${$Text} =~ s/</&lt;/g;
    ${$Text} =~ s/>/&gt;/g;
    ${$Text} =~ s/"/&quot;/g;

    # text -> html format quoting
    if ( $Param{LinkFeature} ) {
        for my $Filter (@Filters) {
            $Text = $Filter->{Object}->Post(
                Filter => $Filter->{Filter},
                Data   => $Text,
            );
        }
    }

    if ( $Param{HTMLResultMode} ) {
        ${$Text} =~ s/\n/<br\/>\n/g;
        ${$Text} =~ s/  /&nbsp;&nbsp;/g;

        # Convert the space at the beginning of the line (see bug#14346 - https://bugs.otrs.org/show_bug.cgi?id=14346).
        ${$Text} =~ s/\n /\n&nbsp;/g;
    }

    if ( $Param{Type} && $Param{Type} eq 'JSText' ) {
        ${$Text} =~ s/'/\\'/g;
    }

    return $Text if ref $Param{Text};
    return ${$Text};
}

=head2 LinkQuote()

detect links in text

    my $HTMLWithLinks = $LayoutObject->LinkQuote(
        Text => $HTMLWithOutLinks,
    );

also string ref is possible

    my $HTMLWithLinksRef = $LayoutObject->LinkQuote(
        Text => \$HTMLWithOutLinksRef,
    );

=cut

sub LinkQuote {
    my ( $Self, %Param ) = @_;

    my $Text   = $Param{Text}   || '';
    my $Target = $Param{Target} || 'NewPage' . int( rand(199) );

    # check ref
    my $TextScalar;
    if ( !ref $Text ) {
        $TextScalar = $Text;
        $Text       = \$TextScalar;
    }

    # run output filter text
    my @Filters;
    if ( $Self->{FilterText} && ref $Self->{FilterText} eq 'HASH' ) {

        # extract filter list
        my %FilterList = %{ $Self->{FilterText} };

        my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

        FILTER:
        for my $Filter ( sort keys %FilterList ) {

            # extract filter config
            my $FilterConfig = $FilterList{$Filter};

            next FILTER if !$FilterConfig;
            next FILTER if ref $FilterConfig ne 'HASH';

            # extract template list
            my $TemplateList = $FilterConfig->{Templates};

            # check template list
            if ( !$TemplateList || ref $TemplateList ne 'HASH' || !%{$TemplateList} ) {

                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  =>
                        "Please add a template list to output filter $FilterConfig->{Module} "
                        . "to improve performance. Use ALL if OutputFilter should modify all "
                        . "templates of the system (deprecated).",
                );
            }

            # check template list
            if ( $Param{TemplateFile} && ref $TemplateList eq 'HASH' && !$TemplateList->{ALL} ) {
                next FILTER if !$TemplateList->{ $Param{TemplateFile} };
            }

            $Self->FatalDie() if !$MainObject->Require( $FilterConfig->{Module} );

            # create new instance
            my $Object = $FilterConfig->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
            );

            next FILTER if !$Object;

            push @Filters, {
                Object => $Object,
                Filter => $FilterConfig,
            };
        }
    }

    for my $Filter (@Filters) {
        $Text = $Filter->{Object}->Pre(
            Filter => $Filter->{Filter},
            Data   => $Text
        );
    }
    for my $Filter (@Filters) {
        $Text = $Filter->{Object}->Post(
            Filter => $Filter->{Filter},
            Data   => $Text
        );
    }

    # do mail to quote
    ${$Text} =~ s/(mailto:.+?)(\.\s|\s|\)|\"|]|')/<a href=\"$1\">$1<\/a>$2/gi;

    # check ref && return result like called
    if ($TextScalar) {
        return ${$Text};
    }
    else {
        return $Text;
    }
}

=head2 HTMLLinkQuote()

detect links in HTML code

    my $HTMLWithLinks = $LayoutObject->HTMLLinkQuote(
        String => $HTMLString,
    );

also string ref is possible

    my $HTMLWithLinksRef = $LayoutObject->HTMLLinkQuote(
        String => \$HTMLString,
    );

=cut

sub HTMLLinkQuote {
    my ( $Self, %Param ) = @_;

    return $Kernel::OM->Get('Kernel::System::HTMLUtils')->LinkQuote(
        String    => $Param{String},
        TargetAdd => 1,
        Target    => '_blank',
    );
}

=head2 LinkEncode()

perform URL encoding on query string parameter names or values.

    my $ParamValueEncoded = $LayoutObject->LinkEncode($ParamValue);

Don't encode entire URLs, because this will make them invalid
(?, & and ; will be encoded as well). Only pass one parameter name
or value at a time.

=cut

sub LinkEncode {
    my ( $Self, $Link ) = @_;

    return if !defined $Link;

    return uri_escape_utf8($Link);
}

sub CustomerAgeInHours {
    my ( $Self, %Param ) = @_;

    my $Age       = defined( $Param{Age} ) ? $Param{Age} : return;
    my $Space     = $Param{Space} || '<br/>';
    my $AgeStrg   = '';
    my $HourDsc   = Translatable('h');
    my $MinuteDsc = Translatable('m');
    if ( $Kernel::OM->Get('Kernel::Config')->Get('TimeShowCompleteDescription') ) {
        $HourDsc   = Translatable('hour(s)');
        $MinuteDsc = Translatable('minute(s)');
    }
    if ( $Age =~ /^-(.*)/ ) {
        $Age     = $1;
        $AgeStrg = '-';
    }

    # get hours
    if ( $Age >= 3600 ) {
        $AgeStrg .= int( ( $Age / 3600 ) ) . ' ';
        $AgeStrg .= $Self->{LanguageObject}->Translate($HourDsc);
        $AgeStrg .= $Space;
    }

    # get minutes (just if age < 1 day)
    if ( $Age <= 3600 || int( ( $Age / 60 ) % 60 ) ) {
        $AgeStrg .= int( ( $Age / 60 ) % 60 ) . ' ';
        $AgeStrg .= $Self->{LanguageObject}->Translate($MinuteDsc);
    }
    return $AgeStrg;
}

sub CustomerAge {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my $Age       = defined( $Param{Age} ) ? $Param{Age} : return;
    my $Space     = $Param{Space} || '<br/>';
    my $AgeStrg   = '';
    my $DayDsc    = Translatable('d');
    my $HourDsc   = Translatable('h');
    my $MinuteDsc = Translatable('m');
    if ( $ConfigObject->Get('TimeShowCompleteDescription') ) {
        $DayDsc    = Translatable('day(s)');
        $HourDsc   = Translatable('hour(s)');
        $MinuteDsc = Translatable('minute(s)');
    }
    if ( $Age =~ /^-(.*)/ ) {
        $Age     = $1;
        $AgeStrg = '-';
    }

    # get days
    if ( $Age >= 86400 ) {
        $AgeStrg .= int( ( $Age / 3600 ) / 24 ) . ' ';
        $AgeStrg .= $Self->{LanguageObject}->Translate($DayDsc);
        $AgeStrg .= $Space;
    }

    # get hours
    if ( $Age >= 3600 ) {
        $AgeStrg .= int( ( $Age / 3600 ) % 24 ) . ' ';
        $AgeStrg .= $Self->{LanguageObject}->Translate($HourDsc);
        $AgeStrg .= $Space;
    }

    # get minutes (just if age < 1 day)
    if ( ( $Param{TimeShowAlwaysLong} || $ConfigObject->Get('TimeShowAlwaysLong') || $Age < 86400 ) && $Age != 0 ) {
        $AgeStrg .= int( ( $Age / 60 ) % 60 ) . ' ';
        $AgeStrg .= $Self->{LanguageObject}->Translate($MinuteDsc);
    }
    return $AgeStrg;
}

=head2 BuildSelection()

build a HTML option element based on given data

    my $HTML = $LayoutObject->BuildSelection(
        Data            => $ArrayRef,        # use $HashRef, $ArrayRef or $ArrayHashRef (see below)
        Name            => 'TheName',        # name of element
        ID              => 'HTMLID',         # (optional) the HTML ID for this element, if not provided, the name will be used as ID as well
        Multiple        => 0,                # (optional) default 0 (0|1)
        Size            => 1,                # (optional) default 1 element size
        Class           => 'class',          # (optional) a css class, include 'Modernize' to activate InputFields
        Disabled        => 0,                # (optional) default 0 (0|1) disable the element
        AutoComplete    => 'off',            # (optional)
        OnChange        => 'javascript',     # (optional)
        OnClick         => 'javascript',     # (optional)

        SelectedID     => 1,                 # (optional) use integer or arrayref (unable to use with ArrayHashRef)
        SelectedID     => [1, 5, 3],         # (optional) use integer or arrayref (unable to use with ArrayHashRef)
        SelectedValue  => 'test',            # (optional) use string or arrayref (unable to use with ArrayHashRef)
        SelectedValue  => ['test', 'test1'], # (optional) use string or arrayref (unable to use with ArrayHashRef)

        Sort           => 'NumericValue',    # (optional) (AlphanumericValue|NumericValue|AlphanumericKey|NumericKey|TreeView|IndividualKey|IndividualValue) unable to use with ArrayHashRef
        SortIndividual => ['sec', 'min']     # (optional) only sort is set to IndividualKey or IndividualValue
        SortReverse    => 0,                 # (optional) reverse the list

        Translation    => 1,                 # (optional) default 1 (0|1) translate value
        PossibleNone   => 0,                 # (optional) default 0 (0|1) add a leading empty selection
        TreeView       => 0,                 # (optional) default 0 (0|1)
        DisabledBranch => 'Branch',          # (optional) disable all elements of this branch (use string or arrayref)
        Max            => 100,               # (optional) default 100 max size of the shown value
        HTMLQuote      => 0,                 # (optional) default 1 (0|1) disable html quote
        Title          => 'C<Tooltip> Text',    # (optional) string will be shown as c<Tooltip> on c<mouseover>
        OptionTitle    => 1,                 # (optional) default 0 (0|1) show title attribute (the option value) on every option element

        Filters => {                         # (optional) filter data, used by InputFields
            LastOwners => {                  # filter id
                Name   => 'Last owners',     # name of the filter
                Values => {                  # filtered data structure
                    Key1 => 'Value1',
                    Key2 => 'Value2',
                    Key3 => 'Value3',
                },
                Active => 1,                 # (optional) default 0 (0|1) make this filter immediately active
            },
            InvolvedAgents => {
                Name   => 'Involved in this ticket',
                Values => \%HashWithData,
            },
        },
        ExpandFilters  => 1,                 # (optional) default 0 (0|1) expand filters list by default

        ValidateDateAfter  => '2016-01-01',  # (optional) validate that date is after supplied value
        ValidateDateBefore => '2016-01-01',  # (optional) validate that date is before supplied value
    );

    my $HashRef = {
        Key1 => 'Value1',
        Key2 => 'Value2',
        Key3 => 'Value3',
    };

    my $ArrayRef = [
        'KeyValue1',
        'KeyValue2',
        'KeyValue3',
        'KeyValue4',
    ];

    my $ArrayHashRef = [
        {
            Key   => '1',
            Value => 'Value1',
        },
        {
            Key      => '2',
            Value    => 'Value1::Subvalue1',
            Selected => 1,
        },
        {
            Key   => '3',
            Value => 'Value1::Subvalue2',
        },
        {
            Key      => '4',
            Value    => 'Value2',
            Disabled => 1,
        }
    ];

=cut

sub BuildSelection {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(Name Data)) {
        if ( !$Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # The parameters 'Ajax' and 'OnChange' are exclusive
    if ( $Param{Ajax} && $Param{OnChange} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "The parameters 'OnChange' and 'Ajax' exclude each other!"
        );
        return;
    }

    # set OnChange if AJAX is used
    if ( $Param{Ajax} ) {
        if ( !$Param{Ajax}->{Depend} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'Need Depend Param Ajax option!',
            );
            $Self->FatalError();
        }
        if ( !$Param{Ajax}->{Update} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'Need Update Param Ajax option()!',
            );
            $Self->FatalError();
        }
        my $Selector = $Param{ID} || $Param{Name};
        $Param{OnChange} = "Core.AJAX.FormUpdate(\$('#"
            . $Selector . "'), '" . $Param{Ajax}->{Subaction} . "',"
            . " '$Param{Name}',"
            . " ['"
            . join( "', '", @{ $Param{Ajax}->{Update} } ) . "']);";
    }

    # create OptionRef
    my $OptionRef = $Self->_BuildSelectionOptionRefCreate(%Param);

    # create AttributeRef
    my $AttributeRef = $Self->_BuildSelectionAttributeRefCreate(%Param);

    # create DataRef
    my $DataRef = $Self->_BuildSelectionDataRefCreate(
        Data         => $Param{Data},
        AttributeRef => $AttributeRef,
        OptionRef    => $OptionRef,
    );

    # create FiltersRef
    my @Filters;
    my $FilterActive;
    if ( $Param{Filters} ) {
        my $Index = 1;
        for my $Filter ( sort keys %{ $Param{Filters} } ) {
            if (
                $Param{Filters}->{$Filter}->{Name}
                && $Param{Filters}->{$Filter}->{Values}
                )
            {
                my $FilterData = $Self->_BuildSelectionDataRefCreate(
                    Data         => $Param{Filters}->{$Filter}->{Values},
                    AttributeRef => $AttributeRef,
                    OptionRef    => $OptionRef,
                );
                push @Filters, {
                    Name => $Param{Filters}->{$Filter}->{Name},
                    Data => $FilterData,
                };
                if ( $Param{Filters}->{$Filter}->{Active} ) {
                    $FilterActive = $Index;
                }
            }
            else {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => 'Each Filter must provide Name and Values!',
                );
                $Self->FatalError();
            }
            $Index++;
        }
        @Filters = sort { $a->{Name} cmp $b->{Name} } @Filters;
    }

    # generate output
    my $String = $Self->_BuildSelectionOutput(
        AttributeRef       => $AttributeRef,
        DataRef            => $DataRef,
        OptionTitle        => $Param{OptionTitle},
        TreeView           => $Param{TreeView},
        FiltersRef         => \@Filters,
        FilterActive       => $FilterActive,
        ExpandFilters      => $Param{ExpandFilters},
        ValidateDateAfter  => $Param{ValidateDateAfter},
        ValidateDateBefore => $Param{ValidateDateBefore},
    );
    return $String;
}

sub NoPermission {
    my ( $Self, %Param ) = @_;

    my $WithHeader = $Param{WithHeader} || 'yes';

    if ( !$Param{Message} ) {
        $Param{Message} = $Self->{LanguageObject}->Translate(
            "This ticket does not exist, or you don't have permissions to access it in its current state. You can take one of the following actions:"
        );
    }

    # get config option for possible next actions
    my $PossibleNextActions = $Kernel::OM->Get('Kernel::Config')->Get('PossibleNextActions');

    POSSIBLE:
    if ( IsHashRefWithData($PossibleNextActions) ) {
        $Self->Block(
            Name => 'PossibleNextActionContainer',
        );
        for my $Key ( sort keys %{$PossibleNextActions} ) {
            next POSSIBLE if !$Key;
            next POSSIBLE if !$PossibleNextActions->{$Key};

            $Self->Block(
                Name => 'PossibleNextActionRow',
                Data => {
                    Link        => $Key,
                    Description => $PossibleNextActions->{$Key},
                },
            );
        }
    }

    # create output
    my $Output;
    $Output = $Self->Header( Title => 'Insufficient Rights' ) if $WithHeader eq 'yes';
    $Output .= $Self->Output(
        TemplateFile => 'NoPermission',
        Data         => \%Param
    );
    $Output .= $Self->Footer() if $WithHeader eq 'yes';

    # return output
    return $Output;
}

=head2 Permission()

check if access to a frontend module exists

    my $Access = $LayoutObject->Permission(
        Action => 'AdminCustomerUser',
        Type   => 'rw', # ro|rw possible
    );

=cut

sub Permission {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw(Action Type)) {
        if ( !defined $Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Got no $Needed!",
            );
            $Self->FatalError();
        }
    }

    # Get config option for frontend module.
    my $Config = $Kernel::OM->Get('Kernel::Config')->Get('Frontend::Module')->{ $Param{Action} };
    return if !$Config;

    my $Item = $Config->{ $Param{Type} eq 'ro' ? 'GroupRo' : 'Group' };

    my $GroupObject = $Kernel::OM->Get(
        $Self->{UserType} eq 'Customer' ? 'Kernel::System::CustomerGroup' : 'Kernel::System::Group'
    );

    # No access restriction?
    if (
        ref $Config->{GroupRo} eq 'ARRAY'
        && !scalar @{ $Config->{GroupRo} }
        && ref $Config->{Group} eq 'ARRAY'
        && !scalar @{ $Config->{Group} }
        )
    {
        return 1;
    }

    # Array access restriction.
    elsif ( IsArrayRefWithData($Item) ) {
        for my $GroupName ( @{$Item} ) {
            return 1 if $GroupObject->PermissionCheck(
                UserID    => $Self->{UserID},
                GroupName => $GroupName,
                Type      => $Param{Type},
            );
        }
    }

    # Allow access if there is no configuration for module group permission.
    elsif ( !IsArrayRefWithData( $Config->{GroupRo} ) && !IsArrayRefWithData( $Config->{Group} ) ) {
        return 1;
    }

    return 0;
}

sub ReturnValue {
    my ( $Self, $What ) = @_;

    return $Self->{$What};
}

=head2 Attachment()

returns browser output to display/download a attachment.

    $HTML = $LayoutObject->Attachment(
        Type             => 'inline',          # optional, default: attachment, possible: inline|attachment
        Filename         => 'FileName.png',    # optional
        AdditionalHeader => [ $key => $val ]   # optional, an array ref
        ContentType      => 'image/png',
        Content          => $Content,
        Sandbox          => 1,                 # optional, default 0; use content security policy to prohibit external
                                               #   scripts, flash etc.
    );

Or for AJAX html snippets:

    $HTML = $LayoutObject->Attachment(
        Type        => 'inline',        # optional, default: attachment, possible: inline|attachment
        Filename    => 'FileName.html', # optional
        ContentType => 'text/html',
        Charset     => 'utf-8',         # optional
        Content     => $Content,
        NoCache     => 1,               # optional
    );

As a side effect the headers of the HTTP response are set in the object C<Kernel::System::Web::Response>.

=cut

sub Attachment {
    my ( $Self, %Param ) = @_;

    # check needed params
    for (qw(Content ContentType)) {
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Got no $_!",
            );
            $Self->FatalError();
        }
    }

    # get singletons
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my %Headers;

    # return attachment
    {
        my $ContentDisposition = '';
        if ( $Param{Type} ) {
            $ContentDisposition .= $Param{Type};
            $ContentDisposition .= '; ';
        }
        else {
            $ContentDisposition .= $ConfigObject->Get('AttachmentDownloadType') || 'attachment';
            $ContentDisposition .= '; ';
        }

        if ( $Param{Filename} ) {

            # IE 10+ supports this
            my $URLEncodedFilename = uri_escape_utf8( $Param{Filename} );
            $ContentDisposition .= " filename=\"$Param{Filename}\"; filename*=utf-8''$URLEncodedFilename";
        }
        $Headers{'Content-Disposition'} = $ContentDisposition;
    }

    # add no cache headers
    if ( $Param{NoCache} ) {
        $Headers{'Expires'}       = 'Tue, 1 Jan 1980 12:00:00 GMT';
        $Headers{'Cache-Control'} = 'no-cache';
        $Headers{'Pragma'}        = 'no-cache';
    }

    if ( !$ConfigObject->Get('DisableIFrameOriginRestricted') ) {
        $Headers{'X-Frame-Options'} = 'SAMEORIGIN';
    }

    if ( $Param{Sandbox} && !$Kernel::OM->Get('Kernel::Config')->Get('DisableContentSecurityPolicy') ) {

        # Disallow external and inline scripts, active content, frames, but keep allowing inline styles
        #   as this is a common use case in emails.
        # Also disallow referrer headers to prevent referrer leaks via old-style policy directive. Please note this has
        #   been deprecated and will be removed in future OTOBO versions in favor of a separate header (see below).
        # img-src:    allow external and inline (data:) images
        # script-src: block all scripts
        # object-src: allow 'self' so that the browser can load plugins for PDF display
        # frame-src:  block all frames
        # style-src:  allow inline styles for nice email display
        # referrer:   don't send referrers to prevent referrer-leak attacks
        $Headers{'Content-Security-Policy'}
            = q{default-src *; img-src * data:; script-src 'none'; object-src 'self'; frame-src 'none'; style-src 'unsafe-inline'; referrer no-referrer;};

        # Use Referrer-Policy header to suppress referrer information in modern browsers
        #   (to prevent referrer-leak attacks).
        $Headers{'Referrer-Policy'} = 'no-referrer';
    }

    if ( $Param{Charset} ) {
        $Headers{'Content-Type'} = "$Param{ContentType}; charset=$Param{Charset};";
    }
    else {
        $Headers{'Content-Type'} = "$Param{ContentType}";
    }

    # additional headers are supported, but currently not used
    my @AdditionalHeaders = ( $Param{AdditionalHeader} // [] )->@*;
    $Kernel::OM->Get('Kernel::System::Web::Response')->Headers( [ %Headers, @AdditionalHeaders ] );

    # fix for firefox HEAD problem
    my $RequestMethod = $Kernel::OM->Get('Kernel::System::Web::Request')->RequestMethod();
    if ( $RequestMethod && $RequestMethod eq 'HEAD' ) {
        return '';
    }

    return $Param{Content};
}

=head2 PageNavBar()

generates a page navigation bar

    my %PageNavBar = $LayoutObject->PageNavBar(
        Limit       => 100,         # marks result of TotalHits red if Limit is gerater then AllHits
        WindowSize  => 15,          # max shown pages to click
        StartHit    => 1,           # start to show items
        PageShown   => 15,          # number of shown items a page
        AllHits     => 56,          # number of total hits
        Action      => 'AgentXXX',  # e. g. 'Action=' . $Self->{LayoutObject}->{Action}
        Link        => $Link,       # e. g. 'Subaction=View;'
        AJAXReplace => 'IDElement', # IDElement which should be replaced
        IDPrefix    => 'Tickets',   # Prefix for the id parameter
    );

    return values of hash

        TotalHits  # total hits
        Result     # shown items e. g. "1-5" or "16-30"
        SiteNavBar # html for page nav bar e. g. "1 2 3 4"

        ResultLong     # shown items e. g. "1-5 of 32" or "16-30 of 64"
        SiteNavBarLong # html for page nav bar e. g. "Page: 1 2 3 4"

=cut

sub PageNavBar {
    my ( $Self, %Param ) = @_;

    my $Limit = $Param{Limit} || 0;
    $Param{AllHits}  = 0 if ( !$Param{AllHits} );
    $Param{StartHit} = 0 if ( !$Param{AllHits} );
    my $Pages      = int( ( $Param{AllHits} / $Param{PageShown} ) + 0.99999 );
    my $Page       = int( ( $Param{StartHit} / $Param{PageShown} ) + 0.99999 );
    my $WindowSize = $Param{WindowSize} || 5;
    my $IDPrefix   = $Param{IDPrefix}   || 'Generic';

    # build Results (1-5 or 16-30)
    if ( $Param{AllHits} >= ( $Param{StartHit} + $Param{PageShown} ) ) {
        $Param{Results} = $Param{StartHit} . "-" . ( $Param{StartHit} + $Param{PageShown} - 1 );
    }
    else {
        $Param{Results} = "$Param{StartHit}-$Param{AllHits}";
    }

    # check total hits
    if ( $Limit == $Param{AllHits} ) {
        $Param{TotalHits} = "<span class=\"PaginationLimit\">$Param{AllHits}</span>";
    }
    else {
        $Param{TotalHits} = $Param{AllHits};
    }

    # build page nav bar
    my $WindowStart = sprintf( "%.0f", ( $Param{StartHit} / $Param{PageShown} ) );
    $WindowStart = int( ( $WindowStart / $WindowSize ) ) + 1;
    $WindowStart = ( $WindowStart * $WindowSize ) - ($WindowSize);
    my $Action   = $Param{Action} || '';
    my $Link     = $Param{Link}   || '';
    my $Baselink = "$Self->{Baselink}$Action;$Link";
    my $i        = 0;
    my %PaginationData;
    my $WidgetName;
    my $ClassWidgetName;

    if ( $Param{AJAXReplace} ) {
        $WidgetName = $Param{AJAXReplace};
        $WidgetName =~ s{-}{}xmsg;

        $ClassWidgetName = $WidgetName;
        $ClassWidgetName =~ s/^Dashboard//;
    }

    while ( $i <= ( $Pages - 1 ) ) {
        $i++;

        # show normal page 1,2,3,...
        if ( $i <= ( $WindowStart + $WindowSize ) && $i > $WindowStart ) {
            my $BaselinkAll = $Baselink
                . "StartWindow=$WindowStart;StartHit="
                . ( ( ( $i - 1 ) * $Param{PageShown} ) + 1 );
            my $SelectedPage = '';
            my $PageNumber   = $i;

            if ( $Page == $i ) {
                $SelectedPage = 'Selected';
            }
            if ( $Param{AJAXReplace} ) {

                $PaginationData{$PageNumber} = {
                    Baselink    => $BaselinkAll,
                    AjaxReplace => $Param{AJAXReplace},
                    WidgetName  => $ClassWidgetName
                };

                $Self->Block(
                    Name => 'PageAjax',
                    Data => {
                        BaselinkAll  => $BaselinkAll,
                        AjaxReplace  => $Param{AJAXReplace},
                        PageNumber   => $PageNumber,
                        IDPrefix     => $IDPrefix,
                        SelectedPage => $SelectedPage,
                        WidgetName   => $ClassWidgetName
                    },
                );
            }
            else {
                $Self->Block(
                    Name => 'Page',
                    Data => {
                        BaselinkAll  => $BaselinkAll,
                        PageNumber   => $PageNumber,
                        IDPrefix     => $IDPrefix,
                        SelectedPage => $SelectedPage
                    },
                );
            }
        }

        # over window ">>" and ">|"
        elsif ( $i > ( $WindowStart + $WindowSize ) ) {
            my $StartWindow        = $WindowStart + $WindowSize + 1;
            my $LastStartWindow    = int( $Pages / $WindowSize );
            my $BaselinkOneForward = $Baselink . "StartHit=" . ( ( $i - 1 ) * $Param{PageShown} + 1 );
            my $BaselinkAllForward = $Baselink . "StartHit=" . ( ( $Param{PageShown} * ( $Pages - 1 ) ) + 1 );

            if ( $Param{AJAXReplace} ) {
                $PaginationData{$BaselinkOneForward} = {
                    Baselink    => $BaselinkOneForward,
                    AjaxReplace => $Param{AJAXReplace},
                    WidgetName  => $ClassWidgetName
                };
                $PaginationData{$BaselinkAllForward} = {
                    Baselink    => $BaselinkAllForward,
                    AjaxReplace => $Param{AJAXReplace},
                    WidgetName  => $ClassWidgetName
                };

                $Self->Block(
                    Name => 'PageForwardAjax',
                    Data => {
                        BaselinkOneForward => $BaselinkOneForward,
                        BaselinkAllForward => $BaselinkAllForward,
                        AjaxReplace        => $Param{AJAXReplace},
                        IDPrefix           => $IDPrefix,
                        WidgetName         => $ClassWidgetName
                    },
                );
            }
            else {
                $Self->Block(
                    Name => 'PageForward',
                    Data => {
                        BaselinkOneForward => $BaselinkOneForward,
                        BaselinkAllForward => $BaselinkAllForward,
                        IDPrefix           => $IDPrefix,
                    },
                );
            }

            $i = 99999999;
        }

        # over window "<<" and "|<"
        elsif ( $i < $WindowStart && ( $i - 1 ) < $Pages ) {
            my $StartWindow     = $WindowStart - $WindowSize - 1;
            my $BaselinkAllBack = $Baselink . 'StartHit=1;StartWindow=1';
            my $BaselinkOneBack = $Baselink . 'StartHit=' . ( ( $WindowStart - 1 ) * ( $Param{PageShown} ) + 1 );

            if ( $Param{AJAXReplace} ) {

                $PaginationData{$BaselinkOneBack} = {
                    Baselink    => $BaselinkOneBack,
                    AjaxReplace => $Param{AJAXReplace},
                    WidgetName  => $ClassWidgetName
                };
                $PaginationData{$BaselinkAllBack} = {
                    Baselink    => $BaselinkAllBack,
                    AjaxReplace => $Param{AJAXReplace},
                    WidgetName  => $ClassWidgetName
                };

                $Self->Block(
                    Name => 'PageBackAjax',
                    Data => {
                        BaselinkOneBack => $BaselinkOneBack,
                        BaselinkAllBack => $BaselinkAllBack,
                        AjaxReplace     => $Param{AJAXReplace},
                        IDPrefix        => $IDPrefix,
                        WidgetName      => $ClassWidgetName
                    },
                );
            }
            else {
                $Self->Block(
                    Name => 'PageBack',
                    Data => {
                        BaselinkOneBack => $BaselinkOneBack,
                        BaselinkAllBack => $BaselinkAllBack,
                        IDPrefix        => $IDPrefix,
                    },
                );
            }

            $i = $WindowStart - 1;
        }
    }

    # send data to JS
    if ( $Param{AJAXReplace} ) {
        $Self->AddJSData(
            Key   => 'PaginationData' . $ClassWidgetName,
            Value => \%PaginationData
        );
    }

    $Param{SearchNavBar} = $Self->Output(
        TemplateFile => 'Pagination',
        AJAX         => $Param{AJAX},
    );

    # only show total amount of pages if there is more than one
    if ( $Pages > 1 ) {
        $Param{NavBarLong} = "- " . $Self->{LanguageObject}->Translate("Page") . ": $Param{SearchNavBar}";
    }
    else {
        $Param{SearchNavBar} = '';
    }

    # return data
    return (
        TotalHits  => $Param{TotalHits},
        Result     => $Param{Results},
        ResultLong => "$Param{Results} "
            . $Self->{LanguageObject}->Translate("of")
            . " $Param{TotalHits}",
        SiteNavBar     => $Param{SearchNavBar},
        SiteNavBarLong => $Param{NavBarLong},
        Link           => $Param{Link},
    );
}

sub NavigationBar {
    my ( $Self, %Param ) = @_;

    if ( !$Param{Type} ) {
        $Param{Type} = $Self->{ModuleReg}->{NavBarName} || 'Ticket';
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # Create menu items.
    my %NavBar;

    my $FrontendRegistration = $ConfigObject->Get('Frontend::Module');
    my $FrontendNavigation   = $ConfigObject->Get('Frontend::Navigation');

    my $GroupObject = $Kernel::OM->Get('Kernel::System::Group');

    MODULE:
    for my $Module ( sort keys %{$FrontendNavigation} ) {

        # Skip if module is disabled in frontend registration.
        next MODULE if !IsHashRefWithData( $FrontendRegistration->{$Module} );

        # Top-level frontend navigation configuration should always be a hash.
        next MODULE if !IsHashRefWithData( $FrontendNavigation->{$Module} );

        my @ModuleNavigationConfigs;

        # Go through all defined navigation configurations for the module and sort them by the key (00#-Module).
        NAVIGATION_CONFIG:
        for my $Key ( sort keys %{ $FrontendNavigation->{$Module} || {} } ) {
            next NAVIGATION_CONFIG if $Key !~ m{^\d+};

            # FIXME: Support both old (HASH) and new (ARRAY of HASH) navigation configurations, for reasons of backwards
            #   compatibility. Once we are sure everything has been migrated correctly, support for HASH-only
            #   configuration can be dropped in future major release.
            if ( IsHashRefWithData( $FrontendNavigation->{$Module}->{$Key} ) ) {
                push @ModuleNavigationConfigs, $FrontendNavigation->{$Module}->{$Key};
            }
            elsif ( IsArrayRefWithData( $FrontendNavigation->{$Module}->{$Key} ) ) {
                push @ModuleNavigationConfigs, @{ $FrontendNavigation->{$Module}->{$Key} };
            }

            # Skip incompatible configuration.
            else {
                next NAVIGATION_CONFIG;
            }
        }

        ITEM:
        for my $Item (@ModuleNavigationConfigs) {
            next ITEM if !$Item->{NavBar};

            $Item->{CSS} = '';

            # Highlight active area link.
            if (
                ( $Item->{Type} && $Item->{Type} eq 'Menu' )
                && ( $Item->{NavBar} && $Item->{NavBar} eq $Param{Type} )
                )
            {
                $Item->{CSS} .= ' Selected';
            }

            my $InheritPermissions = 0;

            # Inherit permissions from frontend registration if no permissions were defined for the navigation entry.
            if ( !$Item->{GroupRo} && !$Item->{Group} ) {
                if ( $FrontendRegistration->{GroupRo} ) {
                    $Item->{GroupRo} = $FrontendRegistration->{GroupRo};
                }
                if ( $FrontendRegistration->{Group} ) {
                    $Item->{Group} = $FrontendRegistration->{Group};
                }
                $InheritPermissions = 1;
            }

            my $Shown = 0;

            PERMISSION:
            for my $Permission (qw(GroupRo Group)) {

                # No access restriction.
                if (
                    ref $Item->{GroupRo} eq 'ARRAY'
                    && !scalar @{ $Item->{GroupRo} }
                    && ref $Item->{Group} eq 'ARRAY'
                    && !scalar @{ $Item->{Group} }
                    )
                {
                    $Shown = 1;
                    last PERMISSION;
                }

                # Array access restriction.
                elsif ( $Item->{$Permission} && ref $Item->{$Permission} eq 'ARRAY' ) {
                    GROUP:
                    for my $Group ( @{ $Item->{$Permission} } ) {
                        next GROUP if !$Group;
                        my $HasPermission = $GroupObject->PermissionCheck(
                            UserID    => $Self->{UserID},
                            GroupName => $Group,
                            Type      => $Permission eq 'GroupRo' ? 'ro' : 'rw',

                        );
                        if ($HasPermission) {
                            $Shown = 1;
                            last PERMISSION;
                        }
                    }
                }
            }

            # If we passed the initial permission check and didn't inherit permissions from the module registration,
            #   make sure to also check access to the module, since navigation item might be out of sync.
            if ( $Shown && !$InheritPermissions ) {
                my $ModulePermission;

                PERMISSION:
                for my $Permission (qw(GroupRo Group)) {

                    # No access restriction.
                    if (
                        ref $FrontendRegistration->{$Module}->{GroupRo} eq 'ARRAY'
                        && !scalar @{ $FrontendRegistration->{$Module}->{GroupRo} }
                        && ref $FrontendRegistration->{$Module}->{Group} eq 'ARRAY'
                        && !scalar @{ $FrontendRegistration->{$Module}->{Group} }
                        )
                    {

                        $ModulePermission = 1;
                        last PERMISSION;
                    }

                    # Array access restriction.
                    elsif (
                        $FrontendRegistration->{$Module}->{$Permission}
                        && ref $FrontendRegistration->{$Module}->{$Permission} eq 'ARRAY'
                        )
                    {
                        GROUP:
                        for my $Group ( @{ $FrontendRegistration->{$Module}->{$Permission} } ) {
                            next GROUP if !$Group;
                            my $HasPermission = $GroupObject->PermissionCheck(
                                UserID    => $Self->{UserID},
                                GroupName => $Group,
                                Type      => $Permission eq 'GroupRo' ? 'ro' : 'rw',

                            );
                            if ($HasPermission) {
                                $ModulePermission = 1;
                                last PERMISSION;
                            }
                        }
                    }
                }

                # Hide item if no permission was granted to access the module.
                if ( !$ModulePermission ) {
                    $Shown = 0;
                }
            }

            next ITEM if !$Shown;

            # set prio of item
            my $Key = ( $Item->{Block} || '' ) . sprintf( "%07d", $Item->{Prio} );
            COUNT:
            for ( 1 .. 51 ) {
                last COUNT if !$NavBar{$Key};

                $Item->{Prio}++;
                $Key = ( $Item->{Block} || '' ) . sprintf( "%07d", $Item->{Prio} );
            }

            # show as main menu
            if ( $Item->{Type} eq 'Menu' ) {
                $NavBar{$Key} = $Item;
            }

            # show as sub of main menu
            else {
                $NavBar{Sub}->{ $Item->{NavBar} }->{$Key} = $Item;
            }
        }
    }

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    # Run the menu item modules for tweaking the main menu.
    # These modules may add or remove items in the dropdown lists.
    if ( ref $ConfigObject->Get('Frontend::NavBarModule') eq 'HASH' ) {
        my %Jobs = %{ $ConfigObject->Get('Frontend::NavBarModule') };

        MENUMODULE:
        for my $Job ( sort keys %Jobs ) {

            # load module
            next MENUMODULE if !$MainObject->Require( $Jobs{$Job}->{Module} );
            my $Object = $Jobs{$Job}->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
            );
            next MENUMODULE if !$Object;

            # run module
            %NavBar = (
                %NavBar,
                $Object->Run(
                    %Param,
                    Config => $Jobs{$Job},
                    NavBar => \%NavBar || {}
                )
            );
        }
    }

    # show the main menu
    ITEM:
    for my $Key ( sort keys %NavBar ) {
        next ITEM if $Key eq 'Sub';
        next ITEM if !%{ $NavBar{$Key} };
        my $Item = $NavBar{$Key};
        $Item->{NameForID} = $Item->{Name};
        $Item->{NameForID} =~ s/[ &;]//ig;
        my $Sub = $NavBar{Sub}->{ $Item->{NavBar} };

        $Self->Block(
            Name => 'ItemArea',
            Data => {
                %$Item,
                AccessKeyReference => $Item->{AccessKey} ? " ($Item->{AccessKey})" : '',
            },
        );

        # show sub menu (only if sub elements available)
        next ITEM if !$Sub;
        next ITEM if !keys %{$Sub};

        $Self->Block(
            Name => 'ItemAreaSub',
            Data => $Item,
        );

        # Sort Admin sub modules (favorites) correctly. See bug#13103 for more details.
        my @Subs = sort keys %{$Sub};
        if ( $Item->{NameForID} eq 'Admin' ) {
            @Subs = sort { $a <=> $b } keys %{$Sub};
        }

        for my $Key (@Subs) {
            my $ItemSub = $Sub->{$Key};
            $ItemSub->{NameForID} = $ItemSub->{Name};
            $ItemSub->{NameForID} =~ s/[ &;]//ig;
            $ItemSub->{NameTop} = $Item->{NameForID};
            $ItemSub->{Description}
                ||= $ItemSub->{Name};    # use 'name' as fallback, this is shown as the link title
            $Self->Block(
                Name => 'ItemAreaSubItem',    #$Item->{Block} || 'Item',
                Data => {
                    %$ItemSub,
                    AccessKeyReference => $ItemSub->{AccessKey} ? " ($ItemSub->{AccessKey})" : '',
                },
            );
        }
    }

    # get user preferences for custom nav bar item ordering
    my %UserPreferences = $Kernel::OM->Get('Kernel::System::User')->GetPreferences(
        UserID => $Self->{UserID},
    );

    my $NavbarOrderItems = $UserPreferences{'UserNavBarItemsOrder'} || '';
    $Self->AddJSData(
        Key   => 'NavbarOrderItems',
        Value => $NavbarOrderItems,
    );

    my $FrontendSearch = $ConfigObject->Get('Frontend::Search') || {};

    my $SearchAdded;

    # show search icon if any search router is configured
    if ( IsHashRefWithData($FrontendSearch) ) {

        KEY:
        for my $Key ( sort keys %{$FrontendSearch} ) {
            next KEY if !IsHashRefWithData( $FrontendSearch->{$Key} );

            for my $Regex ( sort keys %{ $FrontendSearch->{$Key} } ) {
                next KEY if !$Regex;

                # Check if regex matches current action.
                if ( $Self->{Action} =~ m{$Regex}g ) {

                    # Extract Action from the configuration.
                    my ($Action) = $FrontendSearch->{$Key}->{$Regex} =~ m{Action=(.*?)(;.*)?$};

                    # Do not show Search icon if action is not registered.
                    next KEY if !$FrontendRegistration->{$Action};

                    $Self->Block(
                        Name => 'SearchIcon',
                    );

                    $SearchAdded = 1;
                    last KEY;
                }
            }
        }
    }

    # If Search icon is not added, check if AgentTicketSearch is enabled and add it.
    if ( !$SearchAdded && $FrontendRegistration->{AgentTicketSearch} ) {
        $Self->Block(
            Name => 'SearchIcon',
        );
    }

    # create & return output
    my $Output = $Self->Output(
        TemplateFile => 'AgentNavigationBar',
        Data         => \%Param,
    );

    # Run nav bar output modules. Nav bar output are not used in OTOBO core,
    # but can be used by OTOBO packages. The output of a nav bar output module
    # is spliced in between the main menu and the notification.
    my $NavBarOutputModuleConfig = $ConfigObject->Get('Frontend::NavBarOutputModule');
    if ( ref $NavBarOutputModuleConfig eq 'HASH' ) {
        my %Jobs = $NavBarOutputModuleConfig->%*;

        JOB:
        for my $Job ( sort keys %Jobs ) {

            # load module
            next JOB unless $MainObject->Require( $Jobs{$Job}->{Module} );

            my $Object = $Jobs{$Job}->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
            );

            next JOB unless $Object;

            # run module
            $Output .= $Object->Run( %Param, Config => $Jobs{$Job} );
        }
    }

    # run notification modules
    my $FrontendNotifyModuleConfig = $ConfigObject->Get('Frontend::NotifyModule');
    if ( ref $FrontendNotifyModuleConfig eq 'HASH' ) {
        my %Jobs = $FrontendNotifyModuleConfig->%*;

        JOB:
        for my $Job ( sort keys %Jobs ) {

            # load module
            next JOB unless $MainObject->Require( $Jobs{$Job}->{Module} );

            my $Object = $Jobs{$Job}->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
            );

            next JOB unless $Object;

            # run module
            $Output .= $Object->Run( %Param, Config => $Jobs{$Job} );
        }
    }

    # run nav bar module
    if ( $Self->{NavigationModule} ) {

        # run navbar modules
        my %Jobs = %{ $Self->{NavigationModule} };

        # load module
        if ( !$MainObject->Require( $Jobs{Module} ) ) {
            return $Output;
        }

        my $Object = $Jobs{Module}->new(
            %{$Self},
            LayoutObject => $Self,
        );

        if ( !$Object ) {
            return $Output;
        }

        # run module
        $Output .= $Object->Run( %Param, Config => \%Jobs );
    }

    return $Output;
}

sub TransformDateSelection {
    my ( $Self, %Param ) = @_;

    # get key prefix
    my $Prefix = $Param{Prefix} || '';

    # time zone translation if needed
    # from user time zone to OTOBO time zone
    if ( $Self->{UserTimeZone} ) {
        my $DateTimeObject = $Kernel::OM->Create(
            'Kernel::System::DateTime',
            ObjectParams => {
                Year     => $Param{ $Prefix . 'Year' },
                Month    => $Param{ $Prefix . 'Month' },
                Day      => $Param{ $Prefix . 'Day' },
                Hour     => $Param{ $Prefix . 'Hour' }   || 0,
                Minute   => $Param{ $Prefix . 'Minute' } || 0,
                Second   => $Param{ $Prefix . 'Second' } || 0,
                TimeZone => $Self->{UserTimeZone},
            },
        );

        if ($DateTimeObject) {
            $DateTimeObject->ToOTOBOTimeZone();
            my $DateTimeValues = $DateTimeObject->Get();

            $Param{ $Prefix . 'Year' }   = $DateTimeValues->{Year};
            $Param{ $Prefix . 'Month' }  = $DateTimeValues->{Month};
            $Param{ $Prefix . 'Day' }    = $DateTimeValues->{Day};
            $Param{ $Prefix . 'Hour' }   = $DateTimeValues->{Hour};
            $Param{ $Prefix . 'Minute' } = $DateTimeValues->{Minute};
            $Param{ $Prefix . 'Second' } = $DateTimeValues->{Second};
        }
    }

    # reset prefix
    $Param{Prefix} = '';

    return %Param;
}

=head2 BuildDateSelection()

build the HTML code to represent a date selection based on the given data.
Depending on the SysConfig settings the controls to set the date could be multiple select or input fields

    my $HTML = $LayoutObject->BuildDateSelection(
        Prefix           => 'some prefix',        # optional, (needed to specify other parameters)
        <Prefix>Year     => 2015,                 # optional, defaults to current year, used to set the initial value
        <Prefix>Month    => 6,                    # optional, defaults to current month, used to set the initial value
        <Prefix>Day      => 9,                    # optional, defaults to current day, used to set the initial value
        <Prefix>Hour     => 12,                   # optional, defaults to current hour, used to set the initial value
        <Prefix>Minute   => 26,                   # optional, defaults to current minute, used to set the initial value
        <Prefix>Second   => 59,                   # optional, defaults to current second, used to set the initial value
        <Prefix>Optional => 1,                    # optional, default 0, when active a checkbox is included to specify
                                                  #   if the values should be saved or not
        <Prefix>Used     => 1,                    # optional, default 0, used to set the initial state of the checkbox
                                                  #   mentioned above
        <Prefix>Required => 1,                    # optional, default 0 (Deprecated)
        <prefix>Class    => 'some class',         # optional, specify an additional class to the HTML elements
        Area     => 'some area',                  # optional, default 'Agent' (Deprecated)
        DiffTime => 123,                          # optional, default 0, used to set the initial time influencing the
                                                  #   current time (in seconds)
        OverrideTimeZone => 1,                    # optional (1 or 0), when active the time is not translated to the user
                                                  #   time zone
        YearPeriodFuture => 3,                    # optional, used to define the number of years in future to be display
                                                  #   in the year select
        YearPeriodPast   => 2,                    # optional, used to define the number of years in past to be display
                                                  #   in the year select
        YearDiff         => 0,                    # optional. used to define the number of years to be displayed
                                                  #   in the year select (alternatively to YearPeriodFuture and YearPeriodPast)
        ValidateDateInFuture     => 1,            # optional (1 or 0), when active sets an special class to validate
                                                  #   that the date set in the controls to be in the future
        ValidateDateNotInFuture  => 1,            # optional (1 or 0), when active sets an special class to validate
                                                  #   that the date set in the controls not to be in the future
        ValidateDateAfterPrefix  => 'Start',      # optional (Prefix), when defined sets a special class to validate
                                                  #   that the date set in the controls comes after the date with Prefix
        ValidateDateAfterValue   => '2016-01-01', # optional (Date), when defined sets a special data parameter to validate
                                                  #   that the date set in the controls comes after the supplied date
        ValidateDateBeforePrefix => 'End',        # optional (Prefix), when defined sets a special class to validate
                                                  #   that the date set in the controls comes before the date with Prefix
        ValidateDateBeforeValue  => '2016-01-01', # optional (Date), when defined sets a special data parameter to validate
                                                  #   that the date set in the controls comes before the supplied date
        Calendar => 2,                            # optional, used to define the SysConfig calendar on which the Datepicker
                                                  #   will be based on to show the vacation days and the start week day
        Format   => 'DateInputFormat',            # optional, or 'DateInputFormatLong', used to define if only date or
                                                  #   date/time components should be shown (DateInputFormatLong shows date/time)
        Validate => 1,                            # optional (1 or 0), defines if the date selection should be validated on
                                                  #   client side with JS
        Disabled => 1,                            # optional (1 or 0), when active select and checkbox controls gets the
                                                  #   disabled attribute and input fields gets the read only attribute
        Suffix => 'some suffix',                  # optional, is attachted at the end of Names, IDs etc.
    );

=cut

sub BuildDateSelection {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my $DateInputStyle = $ConfigObject->Get('TimeInputFormat');
    my $MinuteStep     = $ConfigObject->Get('TimeInputMinutesStep');
    my $Prefix         = $Param{Prefix}   || '';
    my $Suffix         = $Param{Suffix}   || '';
    my $DiffTime       = $Param{DiffTime} || 0;
    my $Format         = defined( $Param{Format} ) ? $Param{Format} : 'DateInputFormatLong';
    my $Area           = $Param{Area}                   || 'Agent';
    my $Optional       = $Param{ $Prefix . 'Optional' } || 0;
    my $Required       = $Param{ $Prefix . 'Required' } || 0;
    my $Used           = $Param{ $Prefix . 'Used' }     || 0;
    my $Class          = $Param{ $Prefix . 'Class' }    || '';

    # Defines, if the date selection should be validated on client side with JS
    my $Validate = $Param{Validate} || 0;

    # Validate that the date is in the future (e. g. pending times)
    my $ValidateDateInFuture    = $Param{ValidateDateInFuture}    || 0;
    my $ValidateDateNotInFuture = $Param{ValidateDateNotInFuture} || 0;

    # Validate that the date is set after/before supplied date
    my $ValidateDateAfterPrefix  = $Param{ValidateDateAfterPrefix}  || '';
    my $ValidateDateAfterValue   = $Param{ValidateDateAfterValue}   || '';
    my $ValidateDateBeforePrefix = $Param{ValidateDateBeforePrefix} || '';
    my $ValidateDateBeforeValue  = $Param{ValidateDateBeforeValue}  || '';

    my $GetCurSysDTUnitFromLowest = sub {
        my %Param = @_;

        my $DateTimeObject = $Kernel::OM->Create(
            'Kernel::System::DateTime',
            ObjectParams => {
                TimeZone => $Self->{UserTimeZone}
            }
        );
        if ( $Param{AddSeconds} ) {
            $DateTimeObject->Add( Seconds => $Param{AddSeconds} );
        }

        my %Details = %{ $DateTimeObject->Get() };

        return map { $Details{$_} } (qw(Second Minute Hour Day Month Year));
    };

    my ( $s, $m, $h, $D, $M, $Y ) = $GetCurSysDTUnitFromLowest->(
        AddSeconds => $DiffTime,
    );
    my ( $Cs, $Cm, $Ch, $CD, $CM, $CY ) = $GetCurSysDTUnitFromLowest->();

    # time zone translation
    if (
        $Self->{UserTimeZone}
        && $Param{ $Prefix . 'Year' }
        && $Param{ $Prefix . 'Month' }
        && $Param{ $Prefix . 'Day' }
        && !$Param{OverrideTimeZone}
        )
    {
        my $DateTimeObject = $Kernel::OM->Create(
            'Kernel::System::DateTime',
            ObjectParams => {
                Year   => $Param{ $Prefix . 'Year' },
                Month  => $Param{ $Prefix . 'Month' },
                Day    => $Param{ $Prefix . 'Day' },
                Hour   => $Param{ $Prefix . 'Hour' }   || 0,
                Minute => $Param{ $Prefix . 'Minute' } || 0,
                Second => $Param{ $Prefix . 'Second' } || 0,
            },
        );

        if ($DateTimeObject) {
            $DateTimeObject->ToTimeZone( TimeZone => $Self->{UserTimeZone} );
            my $DateTimeValues = $DateTimeObject->Get();

            $Param{ $Prefix . 'Year' }   = $DateTimeValues->{Year};
            $Param{ $Prefix . 'Month' }  = $DateTimeValues->{Month};
            $Param{ $Prefix . 'Day' }    = $DateTimeValues->{Day};
            $Param{ $Prefix . 'Hour' }   = $DateTimeValues->{Hour};
            $Param{ $Prefix . 'Minute' } = $DateTimeValues->{Minute};
            $Param{ $Prefix . 'Second' } = $DateTimeValues->{Second};
        }
    }

    # year
    if ( $DateInputStyle eq 'Option' ) {
        my %Year;
        if ( defined $Param{YearPeriodPast} && defined $Param{YearPeriodFuture} ) {
            for ( $Y - $Param{YearPeriodPast} .. $Y + $Param{YearPeriodFuture} ) {
                $Year{$_} = $_;
            }
        }
        else {
            for ( 2001 .. $Y + 1 + ( $Param{YearDiff} || 0 ) ) {
                $Year{$_} = $_;
            }
        }

        # Check if the DiffTime is in a future year. In this case, we add the missing years between
        # $CY (current year) and $Y (year) to allow the user to manually set back the year if needed.
        if ( $Y > $CY ) {
            for ( $CY .. $Y ) {
                $Year{$_} = $_;
            }
        }

        $Param{Year} = $Self->BuildSelection(
            Name        => $Prefix . 'Year' . $Suffix,
            Data        => \%Year,
            SelectedID  => int( $Param{ $Prefix . 'Year' } || $Y ),
            Translation => 0,
            Class       => $Validate ? "Validate_DateYear $Class" : $Class,
            Title       => $Self->{LanguageObject}->Translate('Year'),
            Disabled    => $Param{Disabled},
        );
    }
    else {
        $Param{Year} = "<input type=\"text\" "
            . ( $Validate ? "class=\"Validate_DateYear $Class\" " : "class=\"$Class\" " )
            . "name=\"${Prefix}Year${Suffix}\" id=\"${Prefix}Year${Suffix}\" size=\"4\" maxlength=\"4\" "
            . "title=\""
            . $Self->{LanguageObject}->Translate('Year')
            . "\" value=\""
            . sprintf( "%02d", ( $Param{ $Prefix . 'Year' } || $Y ) ) . "\" "
            . ( $Param{Disabled} ? 'readonly="readonly"' : '' ) . "/>";
    }

    # month
    if ( $DateInputStyle eq 'Option' ) {
        my %Month = map { $_ => sprintf( "%02d", $_ ); } ( 1 .. 12 );
        $Param{Month} = $Self->BuildSelection(
            Name        => $Prefix . 'Month' . $Suffix,
            Data        => \%Month,
            SelectedID  => int( $Param{ $Prefix . 'Month' } || $M ),
            Translation => 0,
            Class       => $Validate ? "Validate_DateMonth $Class" : $Class,
            Title       => $Self->{LanguageObject}->Translate('Month'),
            Disabled    => $Param{Disabled},
        );
    }
    else {
        $Param{Month} = "<input type=\"text\" "
            . ( $Validate ? "class=\"Validate_DateMonth $Class\" " : "class=\"$Class\" " )
            . "name=\"${Prefix}Month${Suffix}\" id=\"${Prefix}Month${Suffix}\" size=\"2\" maxlength=\"2\" "
            . "title=\""
            . $Self->{LanguageObject}->Translate('Month')
            . "\" value=\""
            . sprintf( "%02d", ( $Param{ $Prefix . 'Month' } || $M ) ) . "\" "
            . ( $Param{Disabled} ? 'readonly="readonly"' : '' ) . "/>";
    }

    my $DateValidateClasses = '';
    if ($Validate) {
        $DateValidateClasses
            .= "Validate_DateDay Validate_DateYear_${Prefix}Year${Suffix} Validate_DateMonth_${Prefix}Month${Suffix}";

        if ( $Format eq 'DateInputFormatLong' ) {
            $DateValidateClasses
                .= " Validate_DateHour_${Prefix}Hour${Suffix} Validate_DateMinute_${Prefix}Minute${Suffix}";
        }

        if ($ValidateDateInFuture) {
            $DateValidateClasses .= " Validate_DateInFuture";
        }
        if ($ValidateDateNotInFuture) {
            $DateValidateClasses .= " Validate_DateNotInFuture";
        }
        if ( $ValidateDateAfterPrefix || $ValidateDateAfterValue ) {
            $DateValidateClasses .= ' Validate_DateAfter';
        }
        if ( $ValidateDateBeforePrefix || $ValidateDateBeforeValue ) {
            $DateValidateClasses .= ' Validate_DateBefore';
        }
        if ($ValidateDateAfterPrefix) {
            $DateValidateClasses .= " Validate_DateAfter_$ValidateDateAfterPrefix";
        }
        if ($ValidateDateBeforePrefix) {
            $DateValidateClasses .= " Validate_DateBefore_$ValidateDateBeforePrefix";
        }
    }

    # day
    if ( $DateInputStyle eq 'Option' ) {
        my %Day = map { $_ => sprintf( "%02d", $_ ); } ( 1 .. 31 );
        $Param{Day} = $Self->BuildSelection(
            Name               => $Prefix . 'Day' . $Suffix,
            Data               => \%Day,
            SelectedID         => int( $Param{ $Prefix . 'Day' } || $D ),
            Translation        => 0,
            Class              => "$DateValidateClasses $Class",
            Title              => $Self->{LanguageObject}->Translate('Day'),
            Disabled           => $Param{Disabled},
            ValidateDateAfter  => $ValidateDateAfterValue,
            ValidateDateBefore => $ValidateDateBeforeValue,
        );
    }
    else {
        $Param{Day} = "<input type=\"text\" "
            . "class=\"$DateValidateClasses $Class\" "
            . "name=\"${Prefix}Day${Suffix}\" id=\"${Prefix}Day${Suffix}\" size=\"2\" maxlength=\"2\" "
            . "title=\""
            . $Self->{LanguageObject}->Translate('Day')
            . "\" value=\""
            . sprintf( "%02d", ( $Param{ $Prefix . 'Day' } || $D ) ) . "\" "
            . ( $Param{Disabled} ? 'readonly="readonly"' : '' ) . "/>";

    }
    if ( $Format eq 'DateInputFormatLong' ) {

        # hour
        if ( $DateInputStyle eq 'Option' ) {
            my %Hour = map { $_ => sprintf( "%02d", $_ ); } ( 0 .. 23 );
            $Param{Hour} = $Self->BuildSelection(
                Name       => $Prefix . 'Hour' . $Suffix,
                Data       => \%Hour,
                SelectedID => defined( $Param{ $Prefix . 'Hour' } )
                ? int( $Param{ $Prefix . 'Hour' } )
                : int($h),
                Translation => 0,
                Class       => $Validate ? ( 'Validate_DateHour ' . $Class ) : $Class,
                Title       => $Self->{LanguageObject}->Translate('Hours'),
                Disabled    => $Param{Disabled},
            );
        }
        else {
            $Param{Hour} = "<input type=\"text\" "
                . ( $Validate ? "class=\"Validate_DateHour $Class\" " : "class=\"$Class\" " )
                . "name=\"${Prefix}Hour${Suffix}\" id=\"${Prefix}Hour${Suffix}\" size=\"2\" maxlength=\"2\" "
                . "title=\""
                . $Self->{LanguageObject}->Translate('Hours')
                . "\" value=\""
                . sprintf(
                    "%02d",
                    ( defined( $Param{ $Prefix . 'Hour' } ) ? int( $Param{ $Prefix . 'Hour' } ) : $h )
                )
                . "\" "
                . ( $Param{Disabled} ? 'readonly="readonly"' : '' ) . "/>";

        }

        # minute
        if ( $DateInputStyle eq 'Option' ) {
            my %Minute = map { $_ => sprintf( "%02d", $_ ); } map { $_ * $MinuteStep } ( 0 .. ( 60 / $MinuteStep - 1 ) );
            $Param{Minute} = $Self->BuildSelection(
                Name       => $Prefix . 'Minute' . $Suffix,
                Data       => \%Minute,
                SelectedID => defined( $Param{ $Prefix . 'Minute' } )
                ? int( $Param{ $Prefix . 'Minute' } )
                : int( $m - $m % $MinuteStep ),
                Translation => 0,
                Class       => $Validate ? ( 'Validate_DateMinute ' . $Class ) : $Class,
                Title       => $Self->{LanguageObject}->Translate('Minutes'),
                Disabled    => $Param{Disabled},
            );
        }
        else {
            $Param{Minute} = "<input type=\"text\" "
                . ( $Validate ? "class=\"Validate_DateMinute $Class\" " : "class=\"$Class\" " )
                . "name=\"${Prefix}Minute${Suffix}\" id=\"${Prefix}Minute${Suffix}\" size=\"2\" maxlength=\"2\" "
                . "title=\""
                . $Self->{LanguageObject}->Translate('Minutes')
                . "\" value=\""
                . sprintf(
                    "%02d",
                    (
                        defined( $Param{ $Prefix . 'Minute' } )
                        ? int( $Param{ $Prefix . 'Minute' } )
                        : $m
                    )
                ) . "\" "
                . ( $Param{Disabled} ? 'readonly="readonly"' : '' ) . "/>";
        }
    }

    # Get first day of the week
    my $WeekDayStart = $ConfigObject->Get('CalendarWeekDayStart');
    if ( $Param{Calendar} ) {
        if ( $ConfigObject->Get( "TimeZone::Calendar" . $Param{Calendar} . "Name" ) ) {
            $WeekDayStart = $ConfigObject->Get( "CalendarWeekDayStart::Calendar" . $Param{Calendar} );
        }
    }
    if ( !defined $WeekDayStart ) {
        $WeekDayStart = 1;
    }

    my $Output;

    # optional checkbox
    if ($Optional) {
        my $Checked = '';
        if ($Used) {
            $Checked = ' checked="checked"';
        }
        $Output .= "<input type=\"checkbox\" name=\""
            . $Prefix
            . "Used" . $Suffix . "\" id=\"" . $Prefix . "Used" . $Suffix . "\" value=\"1\""
            . $Checked
            . " class=\"$Class\""
            . " title=\""
            . $Self->{LanguageObject}->Translate('Check to activate this date')
            . "\" "
            . ( $Param{Disabled} ? 'disabled="disabled"' : '' )
            . "/>&nbsp;";
    }

    # remove 'Second' because it is never used and bug #9441
    delete $Param{ $Prefix . 'Second' };

    # date format
    $Output .= $Self->{LanguageObject}->Time(
        Action => 'Return',
        Format => 'DateInputFormat',
        Mode   => 'NotNumeric',
        %Param,
    );

    # prepare datepicker for specific calendar
    my $VacationDays = '';
    if ( $Param{Calendar} ) {
        $VacationDays = $Self->DatepickerGetVacationDays(
            Calendar => $Param{Calendar},
        );
    }
    my $VacationDaysJSON = $Self->JSONEncode(
        Data => $VacationDays,
    );

    # Add Datepicker JS to output.
    my $DatepickerJS = '
    Core.UI.Datepicker.Init({
    Day: $("#" + Core.App.EscapeSelector("' . $Prefix . '") + "Day"' . ( $Suffix ? ' + Core.App.EscapeSelector("' . $Suffix . '")' : '' ) . '),
        Month: $("#" + Core.App.EscapeSelector("' . $Prefix . '") + "Month"' . ( $Suffix ? ' + Core.App.EscapeSelector("' . $Suffix . '")' : '' ) . '),
        Year: $("#" + Core.App.EscapeSelector("' . $Prefix . '") + "Year"' . ( $Suffix ? ' + Core.App.EscapeSelector("' . $Suffix . '")' : '' ) . '),
        Hour: $("#" + Core.App.EscapeSelector("' . $Prefix . '") + "Hour"' . ( $Suffix ? ' + Core.App.EscapeSelector("' . $Suffix . '")' : '' ) . '),
        Minute: $("#" + Core.App.EscapeSelector("' . $Prefix . '") + "Minute"' . ( $Suffix ? ' + Core.App.EscapeSelector("' . $Suffix . '")' : '' ) . '),
        VacationDays: ' . $VacationDaysJSON . ',
        DateInFuture: ' .    ( $ValidateDateInFuture    ? 'true' : 'false' ) . ',
        DateNotInFuture: ' . ( $ValidateDateNotInFuture ? 'true' : 'false' ) . ',
        WeekDayStart: ' . $WeekDayStart . '
    });';

    $Self->AddJSOnDocumentComplete( Code => $DatepickerJS );
    $Self->{HasDatepicker} = 1;    # Call some Datepicker init code.

    return $Output;
}

=head2 HumanReadableDataSize()

Produces human readable data size.

    my $SizeStr = $LayoutObject->HumanReadableDataSize(
        Size => 123,  # size in bytes
    );

Returns

    $SizeStr = '123 B';         # example with decimal point: 123.4 MB

=cut

sub HumanReadableDataSize {
    my ( $Self, %Param ) = @_;

    # Use simple string concatenation to format real number. "sprintf" uses dot (.) as decimal separator unless
    #   locale and POSIX (LC_NUMERIC) is used. Even in this case, you are not allowed to use custom separator
    #   (as defined in language files).

    my $FormatSize = sub {
        my ($Number) = @_;

        my $ReadableSize;

        if ( IsInteger($Number) ) {
            $ReadableSize = $Number;
        }
        else {

            # Get integer and decimal parts.
            my ( $Integer, $Float ) = split( /\./, sprintf( "%.1f", $Number ) );

            my $Separator = $Self->{LanguageObject}->{DecimalSeparator} || '.';

            # Format size with provided decimal separator.
            $ReadableSize = $Integer . $Separator . $Float;
        }

        return $ReadableSize;
    };

    if ( !defined( $Param{Size} ) ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Need Size!',
        );
        return;
    }

    if ( !IsInteger( $Param{Size} ) ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Size must be integer!',
        );
        return;
    }

    # Use convention described on https://en.wikipedia.org/wiki/File_size
    my ( $SizeStr, $ReadableSize );

    if ( $Param{Size} >= ( 1024**4 ) ) {

        $ReadableSize = $FormatSize->( $Param{Size} / ( 1024**4 ) );
        $SizeStr      = $Self->{LanguageObject}->Translate( '%s TB', $ReadableSize );
    }
    elsif ( $Param{Size} >= ( 1024**3 ) ) {

        $ReadableSize = $FormatSize->( $Param{Size} / ( 1024**3 ) );
        $SizeStr      = $Self->{LanguageObject}->Translate( '%s GB', $ReadableSize );
    }
    elsif ( $Param{Size} >= ( 1024**2 ) ) {

        $ReadableSize = $FormatSize->( $Param{Size} / ( 1024**2 ) );
        $SizeStr      = $Self->{LanguageObject}->Translate( '%s MB', $ReadableSize );
    }
    elsif ( $Param{Size} >= 1024 ) {

        $ReadableSize = $FormatSize->( $Param{Size} / 1024 );
        $SizeStr      = $Self->{LanguageObject}->Translate( '%s KB', $ReadableSize );
    }
    else {
        $SizeStr = $Self->{LanguageObject}->Translate( '%s B', $Param{Size} );
    }

    return $SizeStr;
}

sub CustomerLogin {
    my ( $Self, %Param ) = @_;

    $Param{TitleArea}   = $Self->{LanguageObject}->Translate('Login') . ' - ';
    $Param{IsLoginPage} = 1;

    # set Action parameter for the loader
    $Self->{Action} = 'CustomerLogin';

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    if ( $ConfigObject->Get('SessionUseCookie') ) {

        # always set a cookie, so that at the time the user submits
        # the password, we know already if the browser supports cookies.
        # ( the session cookie isn't available at that time ).

        # Restrict Cookie to HTTPS if it is used.
        my $CookieSecureAttribute = $ConfigObject->Get('HttpType') eq 'https' ? 1 : undef;

        my $Expires = '+' . $ConfigObject->Get('SessionMaxTime') . 's';
        if ( !$ConfigObject->Get('SessionUseCookieAfterBrowserClose') ) {
            $Expires = '';
        }

        # set a cookie tentatively for checking cookie support
        $Self->{SetCookies}->{OTOBOBrowserHasCookie} = $Kernel::OM->Get('Kernel::System::Web::Request')->SetCookie(
            Key      => 'OTOBOBrowserHasCookie',
            Value    => 1,
            Expires  => $Expires,
            Path     => $ConfigObject->Get('ScriptAlias'),
            Secure   => $CookieSecureAttribute,
            HttpOnly => 1,
        );
    }

    # Add the cookies that had been set in the constructor.
    # The values of $Self->{SetCookies} are plain hash references.
    # For some reason the name eventually used by Cookie::Baker::bake_cookie() is the attribute 'name' of the hashref.
    my $ResponseObject = $Kernel::OM->Get('Kernel::System::Web::Response');
    if (
        $Self->{SetCookies}
        && ref $Self->{SetCookies} eq 'HASH'
        && $ConfigObject->Get('SessionUseCookie')
        )
    {
        for ( sort keys $Self->{SetCookies}->%* ) {

            # make a copy because we might need $Self->{SetCookies} later on
            my %Ingredients = $Self->{SetCookies}->{$_}->%*;
            my $Name        = delete $Ingredients{name};
            $ResponseObject->Cookies->{$Name} = \%Ingredients;
        }
    }

    # check if message should be shown
    if ( $Param{Message} ) {
        $Self->Block(
            Name => 'Message',
            Data => \%Param,
        );
    }
    else {
        $Self->Block(
            Name => 'Signet',
        );
    }

    # Generate the minified CSS and JavaScript files and the tags referencing them (see LayoutLoader)
    $Self->LoaderCreateCustomerCSSCalls();
    $Self->LoaderCreateCustomerJSCalls();
    $Self->LoaderCreateJavaScriptTranslationData();
    $Self->LoaderCreateJavaScriptTemplateData();

    $Self->AddJSData(
        Key   => 'Baselink',
        Value => $Self->{Baselink},
    );

    # Add header logo, if configured
    if ( defined $ConfigObject->Get('CustomerLogo') ) {
        my %CustomerLogo = %{ $ConfigObject->Get('CustomerLogo') };
        my %Data;

        for my $CSSStatement ( sort keys %CustomerLogo ) {
            if ( $CSSStatement eq 'URL' ) {
                my $WebPath = '';
                if ( $CustomerLogo{$CSSStatement} !~ /(http|ftp|https):\//i ) {
                    $WebPath = $ConfigObject->Get('Frontend::WebPath');
                }
                $Data{'URL'} = 'url(' . $WebPath . $CustomerLogo{$CSSStatement} . ')';
            }
            else {
                $Data{$CSSStatement} = $CustomerLogo{$CSSStatement};
            }
        }

        $Self->Block(
            Name => 'HeaderLogoCSS',
            Data => \%Data,
        );

        $Self->Block(
            Name => 'HeaderLogo',
        );
    }

    # get system maintenance object
    my $SystemMaintenanceObject = $Kernel::OM->Get('Kernel::System::SystemMaintenance');

    my $ActiveMaintenance = $SystemMaintenanceObject->SystemMaintenanceIsActive();

    # check if system maintenance is active
    if ($ActiveMaintenance) {
        my $SystemMaintenanceData = $SystemMaintenanceObject->SystemMaintenanceGet(
            ID     => $ActiveMaintenance,
            UserID => 1,
        );
        if ( $SystemMaintenanceData->{ShowLoginMessage} ) {
            my $LoginMessage =
                $SystemMaintenanceData->{LoginMessage}
                || $ConfigObject->Get('SystemMaintenance::IsActiveDefaultLoginMessage')
                || "System maintenance is active, not possible to perform a login!";

            $Self->Block(
                Name => 'SystemMaintenance',
                Data => {
                    LoginMessage => $LoginMessage,
                },
            );
        }
    }

    # show prelogin block, if in prelogin mode (e.g. SSO login)
    if ( defined $Param{'Mode'} && $Param{'Mode'} eq 'PreLogin' ) {
        $Self->Block(
            Name => 'PreLogin',
            Data => \%Param,
        );
    }

    # if not in PreLogin mode, show normal login form
    else {

        my $DisableLoginAutocomplete = $ConfigObject->Get('DisableLoginAutocomplete');
        $Param{UserNameAutocomplete} = $DisableLoginAutocomplete ? 'off' : 'username';
        $Param{PasswordAutocomplete} = $DisableLoginAutocomplete ? 'off' : 'current-password';

        $Self->Block(
            Name => 'LoginBox',
            Data => \%Param,
        );

        # show 2 factor password input if we have at least one backend enabled
        COUNT:
        for my $Count ( '', 1 .. 10 ) {
            next COUNT if !$ConfigObject->Get("Customer::AuthTwoFactorModule$Count");

            $Self->Block(
                Name => 'AuthTwoFactor',
                Data => \%Param,
            );
            last COUNT;
        }

        # get lost password output
        if (
            $ConfigObject->Get('CustomerPanelLostPassword')
            && $ConfigObject->Get('Customer::AuthModule') eq
            'Kernel::System::CustomerAuth::DB'
            )
        {
            $Self->Block(
                Name => 'LostPasswordLink',
                Data => \%Param,
            );
            $Self->Block(
                Name => 'LostPassword',
                Data => \%Param,
            );
        }

        # get create account output
        if (
            $ConfigObject->Get('CustomerPanelCreateAccount')
            && $ConfigObject->Get('Customer::AuthModule') eq
            'Kernel::System::CustomerAuth::DB'
            )

        {
            $Self->Block(
                Name => 'CreateAccountLink',
                Data => \%Param,
            );
            $Self->Block(
                Name => 'CreateAccount',
                Data => \%Param,
            );
        }
    }

    # send data to JS
    $Self->AddJSData(
        Key   => 'LoginFailed',
        Value => $Param{LoginFailed},
    );

    my $BGConfig = $ConfigObject->Get('CustomerLogin::Settings');
    $Param{LoginText}  = $BGConfig->{LoginText} // "Your Tickets. Your OTOBO.";
    $Param{Background} = $BGConfig->{Background} || '';

    # define color scheme
    my $ColorDefinitions = $ConfigObject->Get('CustomerColorDefinitions');
    for my $Color ( sort keys %{$ColorDefinitions} ) {
        $Param{ColorDefinitions} .= "--col$Color:$ColorDefinitions->{ $Color };";
    }

    $Self->_AddHeadersToResponseObject(
        XLoginHeader => 1,
    );

    # create & return output
    return $Self->Output(
        TemplateFile => 'CustomerLogin',
        Data         => \%Param,
    );
}

sub CustomerHeader {
    my ( $Self, %Param ) = @_;

    my $Type = $Param{Type} || '';

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my $File = $Param{Filename} || $Self->{Action} || 'unknown';

    # set file name for "save page as"
    $Param{ContentDisposition} = "filename=\"$File.html\"";

    # area and title
    if (
        !$Param{Area}
        && $ConfigObject->Get('CustomerFrontend::Module')->{ $Self->{Action} }
        )
    {
        $Param{Area} = $ConfigObject->Get('CustomerFrontend::Module')->{ $Self->{Action} }
            ->{NavBarName} || '';
    }
    if (
        !$Param{Title}
        && $ConfigObject->Get('CustomerFrontend::Module')->{ $Self->{Action} }
        )
    {
        $Param{Title} = $ConfigObject->Get('CustomerFrontend::Module')->{ $Self->{Action} }->{Title}
            || '';
    }
    if (
        !$Param{Area}
        && $ConfigObject->Get('PublicFrontend::Module')->{ $Self->{Action} }
        )
    {
        $Param{Area} = $ConfigObject->Get('PublicFrontend::Module')->{ $Self->{Action} }
            ->{NavBarName} || '';
    }
    if (
        !$Param{Title}
        && $ConfigObject->Get('PublicFrontend::Module')->{ $Self->{Action} }
        )
    {
        $Param{Title} = $ConfigObject->Get('PublicFrontend::Module')->{ $Self->{Action} }->{Title}
            || '';
    }
    for my $Word (qw(Value Title Area)) {
        if ( $Param{$Word} ) {
            $Param{TitleArea} .= $Self->{LanguageObject}->Translate( $Param{$Word} ) . ' - ';
        }
    }

    my $Frontend;
    if ( $ConfigObject->Get('CustomerFrontend::Module')->{ $Self->{Action} } ) {
        $Frontend = 'Customer';
    }
    else {
        $Frontend = 'Public';
    }

    # run header meta modules for customer and public frontends
    my $HeaderMetaModule = $ConfigObject->Get( $Frontend . 'Frontend::HeaderMetaModule' );
    if ( ref $HeaderMetaModule eq 'HASH' ) {
        my %Jobs = %{$HeaderMetaModule};

        my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

        MODULE:
        for my $Job ( sort keys %Jobs ) {

            # load and run module
            next MODULE if !$MainObject->Require( $Jobs{$Job}->{Module} );
            my $Object = $Jobs{$Job}->{Module}->new( %{$Self}, LayoutObject => $Self );
            next MODULE if !$Object;
            $Object->Run( %Param, Config => $Jobs{$Job} );
        }
    }

    # set rtl if needed
    if ( $Self->{TextDirection} && $Self->{TextDirection} eq 'rtl' ) {
        $Param{BodyClass} = 'RTL';
    }
    elsif ( $ConfigObject->Get('Frontend::DebugMode') ) {
        $Self->Block(
            Name => 'DebugRTLButton',
        );
    }

    # define (custom) logo
    my $WebPath = $ConfigObject->Get('Frontend::WebPath');
    $Param{URLSignet} = $WebPath . 'skins/Customer/default/img/otobo_signet_w.svg';
    if ( defined $ConfigObject->Get('CustomerLogo') ) {
        my %CustomerLogo = %{ $ConfigObject->Get('CustomerLogo') };

        LOGO:
        for my $Statement (qw(URLSignet)) {
            next LOGO if !$CustomerLogo{$Statement};

            if ( $CustomerLogo{$Statement} !~ /(http|ftp|https):\//i ) {
                $Param{$Statement} = $WebPath . $CustomerLogo{$Statement};
            }
            else {
                $Param{$Statement} = $CustomerLogo{$Statement};
            }
        }
    }

    # Generate the minified CSS and JavaScript files
    # and the tags referencing them (see LayoutLoader)
    $Self->LoaderCreateCustomerCSSCalls();

    # define color scheme
    my $ColorDefinitions = $ConfigObject->Get('CustomerColorDefinitions');
    for my $Color ( sort keys %{$ColorDefinitions} ) {
        $Param{ColorDefinitions} .= "--col$Color:$ColorDefinitions->{ $Color };";
    }

    $Self->_AddHeadersToResponseObject(
        ContentDisposition            => $Param{ContentDisposition},
        DisableIFrameOriginRestricted => $Param{DisableIFrameOriginRestricted},
    );

    # create & return output
    return $Self->Output(
        TemplateFile => "CustomerHeader$Type",
        Data         => \%Param,
    );
}

sub CustomerFooter {
    my ( $Self, %Param ) = @_;

    my $Type          = $Param{Type}           || '';
    my $HasDatepicker = $Self->{HasDatepicker} || 0;

    # Generate the minified CSS and JavaScript files
    # and the tags referencing them (see LayoutLoader)
    $Self->LoaderCreateCustomerJSCalls();
    $Self->LoaderCreateJavaScriptTranslationData();
    $Self->LoaderCreateJavaScriptTemplateData();

    # get datepicker data, if needed in module
    if ($HasDatepicker) {
        my $VacationDays  = $Self->DatepickerGetVacationDays();
        my $TextDirection = $Self->{LanguageObject}->{TextDirection} || '';

        # send data to JS
        $Self->AddJSData(
            Key   => 'Datepicker',
            Value => {
                VacationDays => $VacationDays,
                IsRTL        => ( $TextDirection eq 'rtl' ) ? 1 : 0,
            },
        );
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # Check if video chat is enabled.
    if ( $Kernel::OM->Get('Kernel::System::Main')->Require( 'Kernel::System::VideoChat', Silent => 1 ) ) {
        $Param{VideoChatEnabled} = $Kernel::OM->Get('Kernel::System::VideoChat')->IsEnabled()
            || $Kernel::OM->Get('Kernel::System::Web::Request')->GetParam( Param => 'UnitTestMode' ) // 0;
    }

    # Check if customer user has permission for chat.
    my $CustomerChatPermission;
    if ( $Kernel::OM->Get('Kernel::System::Main')->Require( 'Kernel::System::Chat', Silent => 1 ) ) {

        my $CustomerChatConfig = $ConfigObject->Get('CustomerFrontend::Module')->{'CustomerChat'} || {};

        if (
            $Kernel::OM->Get('Kernel::Config')->Get('CustomerGroupSupport')
            && (
                IsArrayRefWithData( $CustomerChatConfig->{GroupRo} )
                || IsArrayRefWithData( $CustomerChatConfig->{Group} )
            )
            )
        {

            my $CustomerGroupObject = $Kernel::OM->Get('Kernel::System::CustomerGroup');

            GROUP:
            for my $GroupName ( @{ $CustomerChatConfig->{GroupRo} }, @{ $CustomerChatConfig->{Group} } ) {
                $CustomerChatPermission = $CustomerGroupObject->PermissionCheck(
                    UserID    => $Self->{UserID},
                    GroupName => $GroupName,
                    Type      => 'ro',
                );
                last GROUP if $CustomerChatPermission;
            }
        }
        else {
            $CustomerChatPermission = 1;
        }
    }

    # AutoComplete-Config
    my $AutocompleteConfig = $ConfigObject->Get('AutoComplete::Customer');

    for my $ConfigElement ( sort keys %{$AutocompleteConfig} ) {
        $AutocompleteConfig->{$ConfigElement}->{ButtonText}
            = $Self->{LanguageObject}->Translate( $AutocompleteConfig->{$ConfigElement}{ButtonText} );
    }

    # add JS data
    my %JSConfig = (
        Baselink                 => $Self->{Baselink},
        CGIHandle                => $Self->{CGIHandle},
        WebPath                  => $ConfigObject->Get('Frontend::WebPath'),
        Action                   => $Self->{Action},
        Subaction                => $Self->{Subaction},
        SessionIDCookie          => $Self->{SessionIDCookie},
        SessionName              => $Self->{SessionName},
        SessionID                => $Self->{SessionID},
        SessionUseCookie         => $ConfigObject->Get('SessionUseCookie'),
        ChallengeToken           => $Self->{UserChallengeToken},
        CustomerPanelSessionName => $ConfigObject->Get('CustomerPanelSessionName'),
        UserLanguage             => $Self->{UserLanguage},
        CheckEmailAddresses      => $ConfigObject->Get('CheckEmailAddresses'),
        InputFieldsActivated     => 1,
        Autocomplete             => $AutocompleteConfig,
        VideoChatEnabled         => $Param{VideoChatEnabled},
        WebMaxFileUpload         => $ConfigObject->Get('WebMaxFileUpload'),
        CustomerChatPermission   => $CustomerChatPermission,
    );

    for my $Config ( sort keys %JSConfig ) {
        $Self->AddJSData(
            Key   => $Config,
            Value => $JSConfig{$Config},
        );
    }

    # Display footer links.
    my $FooterLinks = $ConfigObject->Get('CustomerFrontend::FooterLinks');
    if ( IsHashRefWithData($FooterLinks) ) {

        my @FooterLinks;
        my %URLConfig = (
            HttpType    => $ConfigObject->Get('HttpType')    // '',
            FQDN        => $ConfigObject->Get('FQDN')        // '',
            ScriptAlias => $ConfigObject->Get('ScriptAlias') // '',
        );

        for my $Link ( sort keys %{$FooterLinks} ) {
            my $SubstitudedLink = $Link;
            for my $Option (qw/HttpType FQDN ScriptAlias/) {
                $SubstitudedLink =~ s/<OTOBO_CONFIG_$Option>/$URLConfig{ $Option }/g;
            }

            push @FooterLinks, {
                Description => $FooterLinks->{$Link},
                Target      => $SubstitudedLink,
            };
        }

        $Param{FooterLinks} = \@FooterLinks;
    }

    # create & return output
    return $Self->Output(
        TemplateFile => "CustomerFooter$Type",
        Data         => \%Param,
    );
}

sub CustomerFatalError {
    my ( $Self, %Param ) = @_;

    # Prevent endless recursion in case of problems with Template engine.
    return if ( $Self->{InFatalError}++ );

    if ( $Param{Message} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Caller   => 1,
            Priority => 'error',
            Message  => $Param{Message},
        );
    }

    my $Output = join '',
        $Self->CustomerHeader(
            Area  => 'Frontend',
            Title => 'Fatal Error'
        ),
        $Self->CustomerError(%Param),
        $Self->CustomerFooter();

    # Modify the output by applying the output filters.
    $Output = $Self->ApplyOutputFilters( Output => $Output );

    # The Content-Length will be set later in the middleware Plack::Middleware::ContentLength. This requires that
    # there are no multi-byte characters in the delivered content. This is because the middleware
    # uses core::length() for determining the content length.
    $Kernel::OM->Get('Kernel::System::Encode')->EncodeOutput( \$Output );

    # The OTOBO response object already has the HTPP headers.
    # Enhance it with the HTTP status code and the content.
    my $PlackResponse = Plack::Response->new(
        200,
        $Kernel::OM->Get('Kernel::System::Web::Response')->Headers(),
        $Output
    );

    # The exception is caught be Plack::Middleware::HTTPExceptions
    die Kernel::System::Web::Exception->new(
        PlackResponse => $PlackResponse
    );
}

sub CustomerNavigationBar {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # create menu items
    my %NavBarModule;
    my $FrontendModule   = $ConfigObject->Get('CustomerFrontend::Module');
    my $NavigationConfig = $ConfigObject->Get('CustomerFrontend::Navigation');

    my $GroupObject = $Kernel::OM->Get('Kernel::System::CustomerGroup');

    MODULE:
    for my $Module ( sort keys %{$NavigationConfig} ) {

        # Skip if module is disabled in frontend registration.
        next MODULE if !IsHashRefWithData( $FrontendModule->{$Module} );

        # Top-level frontend navigation configuration should always be a hash.
        next MODULE if !IsHashRefWithData( $NavigationConfig->{$Module} );

        my @ModuleNavigationConfigs;

        # Go through all defined navigation configurations for the module and sort them by the key (00#-Module).
        NAVIGATION_CONFIG:
        for my $Key ( sort keys %{ $NavigationConfig->{$Module} || {} } ) {
            next NAVIGATION_CONFIG if $Key !~ m{^\d+};

            # FIXME: Support both old (HASH) and new (ARRAY of HASH) navigation configurations, for reasons of backwards
            #   compatibility. Once we are sure everything has been migrated correctly, support for HASH-only
            #   configuration can be dropped in future major release.
            if ( IsHashRefWithData( $NavigationConfig->{$Module}->{$Key} ) ) {
                push @ModuleNavigationConfigs, $NavigationConfig->{$Module}->{$Key};
            }
            elsif ( IsArrayRefWithData( $NavigationConfig->{$Module}->{$Key} ) ) {
                push @ModuleNavigationConfigs, @{ $NavigationConfig->{$Module}->{$Key} };
            }

            # Skip incompatible configuration.
            else {
                next NAVIGATION_CONFIG;
            }
        }

        ITEM:
        for my $Item (@ModuleNavigationConfigs) {
            next ITEM if !$Item->{NavBar};

            my $InheritPermissions = 0;

            # Inherit permissions from frontend registration if no permissions were defined for the navigation entry.
            if ( !$Item->{GroupRo} && !$Item->{Group} ) {
                if ( $FrontendModule->{GroupRo} ) {
                    $Item->{GroupRo} = $FrontendModule->{GroupRo};
                }
                if ( $FrontendModule->{Group} ) {
                    $Item->{Group} = $FrontendModule->{Group};
                }
                $InheritPermissions = 1;
            }

            my $Shown = 0;

            PERMISSION:
            for my $Permission (qw(GroupRo Group)) {

                # No access restriction.
                if (
                    ref $Item->{GroupRo} eq 'ARRAY'
                    && !scalar @{ $Item->{GroupRo} }
                    && ref $Item->{Group} eq 'ARRAY'
                    && !scalar @{ $Item->{Group} }
                    )
                {
                    $Shown = 1;
                    last PERMISSION;
                }

                # Array access restriction.
                elsif ( $Item->{$Permission} && ref $Item->{$Permission} eq 'ARRAY' ) {
                    for my $Group ( @{ $Item->{$Permission} } ) {
                        my $HasPermission = $GroupObject->PermissionCheck(
                            UserID    => $Self->{UserID},
                            GroupName => $Group,
                            Type      => $Permission eq 'GroupRo' ? 'ro' : 'rw',
                        );
                        if ($HasPermission) {
                            $Shown = 1;
                            last PERMISSION;
                        }
                    }
                }
            }

            # If we passed the initial permission check and didn't inherit permissions from the module registration,
            #   make sure to also check access to the module, since navigation item might be out of sync.
            if ( $Shown && !$InheritPermissions ) {
                my $ModulePermission;

                PERMISSION:
                for my $Permission (qw(GroupRo Group)) {

                    # No access restriction.
                    if (
                        ref $FrontendModule->{$Module}->{GroupRo} eq 'ARRAY'
                        && !scalar @{ $FrontendModule->{$Module}->{GroupRo} }
                        && ref $FrontendModule->{$Module}->{Group} eq 'ARRAY'
                        && !scalar @{ $FrontendModule->{$Module}->{Group} }
                        )
                    {

                        $ModulePermission = 1;
                        last PERMISSION;
                    }

                    # Array access restriction.
                    elsif (
                        $FrontendModule->{$Module}->{$Permission}
                        && ref $FrontendModule->{$Module}->{$Permission} eq 'ARRAY'
                        )
                    {
                        GROUP:
                        for my $Group ( @{ $FrontendModule->{$Module}->{$Permission} } ) {
                            next GROUP if !$Group;
                            my $HasPermission = $GroupObject->PermissionCheck(
                                UserID    => $Self->{UserID},
                                GroupName => $Group,
                                Type      => $Permission eq 'GroupRo' ? 'ro' : 'rw',

                            );
                            if ($HasPermission) {
                                $ModulePermission = 1;
                                last PERMISSION;
                            }
                        }
                    }
                }

                # Hide item if no permission was granted to access the module.
                if ( !$ModulePermission ) {
                    $Shown = 0;
                }
            }

            next ITEM if !$Shown;

            # set prio of item
            my $Key = ( $Item->{Block} || '' ) . sprintf( "%07d", $Item->{Prio} );
            COUNT:
            for ( 1 .. 51 ) {
                last COUNT if !$NavBarModule{$Key};

                $Item->{Prio}++;
                $Key = ( $Item->{Block} || '' ) . sprintf( "%07d", $Item->{Prio} );
            }

            # Show as main menu.
            if ( $Item->{Type} eq 'Menu' ) {
                $NavBarModule{$Key} = $Item;
            }

            # show as sub of main menu
            elsif ( $Item->{Type} eq 'Submenu' ) {
                $NavBarModule{Sub}->{ $Item->{NavBar} }->{$Key} = $Item;
            }
        }
    }

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    # run menu item modules
    if ( ref $ConfigObject->Get('CustomerFrontend::NavBarModule') eq 'HASH' ) {
        my %Jobs = %{ $ConfigObject->Get('CustomerFrontend::NavBarModule') };
        for my $Job ( sort keys %Jobs ) {

            # load module
            if ( !$MainObject->Require( $Jobs{$Job}->{Module} ) ) {
                $Self->FatalError();
            }
            my $Object = $Jobs{$Job}->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
                UserID       => $Self->{UserID},
                Debug        => $Self->{Debug},
            );

            # run module
            %NavBarModule = (
                %NavBarModule,
                $Object->Run(
                    %Param,
                    Config       => $Jobs{$Job},
                    NavBarModule => \%NavBarModule || {},
                ),
            );
        }
    }

    my $Total   = keys %NavBarModule;
    my $Counter = 0;

    if ( $NavBarModule{Sub} ) {
        $Total = int($Total) - 1;
    }

    # Only highlight the first matched navigation entry. If there are several entries
    #   with the same Action and Subaction, it cannot be determined which one was used.
    #   Therefore we just highlight the first one.
    ITEM:
    for my $Item ( sort keys %NavBarModule ) {
        next ITEM if !%{ $NavBarModule{$Item} };
        next ITEM if $Item eq 'Sub';

        my $SVGString;
        if ( $NavBarModule{$Item}{svgIcon} ) {
            if ( $NavBarModule{$Item}{svgIcon} !~ /\.svg$/i ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Caller   => 1,
                    Priority => 'error',
                    Message  => "$Item: 'svgIcon' has to be an .svg-file!",
                );
            }

            my $Home   = $ConfigObject->Get('Home');
            my $SVGRef = $MainObject->FileRead(
                Location => "$Home/$NavBarModule{$Item}{svgIcon}",
            );

            if ($SVGRef) {
                $SVGString = ${$SVGRef};
            }
            else {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Caller   => 1,
                    Priority => 'error',
                    Message  => "Could not open $NavBarModule{$Item}{svgIcon}: $!",
                );
            }
        }

        # use the round OTOBO O as the default icon
        if ( !$SVGString ) {
            $SVGString =

                '<svg xmlns="http://www.w3.org/2000/svg" id="radio_button_unchecked-24px" width="50" height="50" viewBox="0 0 50 50">
    <defs>
        <style>
            .cls-1{fill:none}
        </style>
    </defs>
    <path id="Pfad_13735" d="M0 0h50v50H0z" class="cls-1" data-name="Pfad 13735"/>
    <path id="Pfad_13736" d="M22.637 2a20.637 20.637 0 1 0 20.638 20.637A20.645 20.645 0 0 0 22.637 2zm0 37.147a16.51 16.51 0 1 1 16.51-16.51 16.505 16.505 0 0 1-16.51 16.51z" data-name="Pfad 13736" transform="translate(2.363 2.362)"/>
 </svg>';

        }

        $Self->Block(
            Name => $NavBarModule{$Item}->{Block} || 'Item',
            Data => {
                %{ $NavBarModule{$Item} },
                SVG => $SVGString,
            },
        );
    }

    # run notification modules
    my $FrontendNotifyModuleConfig = $ConfigObject->Get('CustomerFrontend::NotifyModule');
    if ( ref $FrontendNotifyModuleConfig eq 'HASH' ) {
        my %Jobs = $FrontendNotifyModuleConfig->%*;

        JOB:
        for my $Job ( sort keys %Jobs ) {

            # load module
            next JOB if !$MainObject->Require( $Jobs{$Job}->{Module} );
            my $Object = $Jobs{$Job}->{Module}->new(
                %{$Self},
                LayoutObject => $Self,
            );
            next JOB if !$Object;

            # run module
            $Param{Notification} .= $Object->Run( %Param, Config => $Jobs{$Job} );
        }
    }

    my %User = $Kernel::OM->Get('Kernel::System::CustomerUser')->CustomerUserDataGet(
        User => $Self->{UserLogin},
    );
    $Param{UserName} = join ' ', ( $User{UserFirstname} // '' ), ( $User{UserLastname} // '' );

    # generate avatar
    if ( $ConfigObject->Get('Frontend::AvatarEngine') eq 'Gravatar' && $Self->{UserEmail} ) {
        my $DefaultIcon = $ConfigObject->Get('Frontend::Gravatar::DefaultImage') || 'mm';
        $Param{Avatar} = '//www.gravatar.com/avatar/' . md5_hex( lc $Self->{UserEmail} ) . '?s=100&d=' . $DefaultIcon;
    }
    else {
        $Param{UserInitials} = substr( $User{UserFirstname}, 0, 1 ) . substr( $User{UserLastname}, 0, 1 );
    }

    # define (custom) logo
    my $WebPath = $ConfigObject->Get('Frontend::WebPath');
    $Param{URLLogo}   = $WebPath . 'skins/Customer/default/img/otobo_logo_simple_w.svg';
    $Param{URLSignet} = $WebPath . 'skins/Customer/default/img/otobo_signet_w.svg';
    if ( defined $ConfigObject->Get('CustomerLogo') ) {
        my %CustomerLogo = %{ $ConfigObject->Get('CustomerLogo') };

        LOGO:
        for my $Statement (qw(URLLogo URLSignet)) {
            next LOGO if !$CustomerLogo{$Statement};

            if ( $CustomerLogo{$Statement} !~ /(http|ftp|https):\//i ) {
                $Param{$Statement} = $WebPath . $CustomerLogo{$Statement};
            }
            else {
                $Param{$Statement} = $CustomerLogo{$Statement};
            }
        }
    }

    # check whether customer preferences should be shown
    PERMISSION:
    for my $Permission (qw(GroupRo Group)) {

        # No access restriction.
        if (
            ref $FrontendModule->{CustomerPreferences}->{GroupRo} eq 'ARRAY'
            && !scalar @{ $FrontendModule->{CustomerPreferences}->{GroupRo} }
            && ref $FrontendModule->{CustomerPreferences}->{Group} eq 'ARRAY'
            && !scalar @{ $FrontendModule->{CustomerPreferences}->{Group} }
            )
        {
            $Param{ShowPreferences} = 1;
            last PERMISSION;
        }

        # Array access restriction.
        elsif (
            $FrontendModule->{CustomerPreferences}->{$Permission}
            && ref $FrontendModule->{CustomerPreferences}->{$Permission} eq 'ARRAY'
            )
        {
            GROUP:
            for my $Group ( @{ $FrontendModule->{CustomerPreferences}->{$Permission} } ) {
                next GROUP if !$Group;
                my $HasPermission = $GroupObject->PermissionCheck(
                    UserID    => $Self->{UserID},
                    GroupName => $Group,
                    Type      => $Permission eq 'GroupRo' ? 'ro' : 'rw',

                );
                if ($HasPermission) {
                    $Param{ShowPreferences} = 1;
                    last PERMISSION;
                }
            }
        }
    }

    # create & return output
    return $Self->Output(
        TemplateFile => 'CustomerNavigationBar',
        Data         => \%Param,
    );

}

sub CustomerError {
    my ( $Self, %Param ) = @_;

    # get backend error messages
    for (qw(Message Traceback)) {
        $Param{ 'Backend' . $_ } = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
            Type => 'Error',
            What => $_
        ) || '';
    }
    if ( !$Param{BackendMessage} && !$Param{BackendTraceback} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => $Param{Message} || '?',
        );
        for (qw(Message Traceback)) {
            $Param{ 'Backend' . $_ } = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
                Type => 'Error',
                What => $_
            ) || '';
        }
    }

    if ( !$Param{Message} ) {
        $Param{Message} = $Param{BackendMessage};
    }

    # create & return output
    return $Self->Output(
        TemplateFile => 'CustomerError',
        Data         => \%Param
    );
}

sub CustomerErrorScreen {
    my ( $Self, %Param ) = @_;

    return join '',
        $Self->CustomerHeader( Title => 'Error' ),
        $Self->CustomerError(%Param),
        $Self->CustomerFooter();
}

sub CustomerWarning {
    my ( $Self, %Param ) = @_;

    # get backend error messages
    $Param{BackendMessage} = $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
        Type => 'Notice',
        What => 'Message',
        )
        || $Kernel::OM->Get('Kernel::System::Log')->GetLogEntry(
            Type => 'Error',
            What => 'Message',
        ) || '';

    if ( !$Param{Message} ) {
        $Param{Message} = $Param{BackendMessage};
    }

    # create & return output
    return $Self->Output(
        TemplateFile => 'CustomerWarning',
        Data         => \%Param
    );
}

sub CustomerNoPermission {
    my ( $Self, %Param ) = @_;

    my $WithHeader = $Param{WithHeader} || 'yes';

    $Param{Message} ||= Translatable('No Permission!');

    # create output
    my $Output;
    $Output = $Self->CustomerHeader( Title => Translatable('No Permission') ) if $WithHeader eq 'yes';
    $Output .= $Self->Output(
        TemplateFile => 'NoPermission',
        Data         => \%Param
    );
    $Output .= $Self->CustomerFooter() if $WithHeader eq 'yes';

    # return output
    return $Output;
}

# similar to CustomerError() but neither the last log message nor the backtrace is printed
sub PublicError {
    my ( $Self, %Param ) = @_;

    # create & return output, using the same layout as in the customer interface
    return $Self->Output(
        TemplateFile => 'CustomerError',
        Data         => \%Param
    );
}

# using PublicError() internally
sub PublicFatalError {
    my ( $Self, %Param ) = @_;

    # Prevent endless recursion in case of problems with Template engine.
    return if $Self->{InFatalError}++;

    if ( $Param{Message} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Caller   => 1,
            Priority => 'error',
            Message  => $Param{Message},
        );
    }

    my $Output = join '',
        $Self->CustomerHeader(
            Area  => 'Frontend',
            Title => 'Fatal Error'
        ),
        $Self->PublicError(%Param),    # without last error message and without last traceback
        $Self->CustomerFooter();

    # Modify the output by applying the output filters.
    $Output = $Self->ApplyOutputFilters( Output => $Output );

    # The Content-Length will be set later in the middleware Plack::Middleware::ContentLength. This requires that
    # there are no multi-byte characters in the delivered content. This is because the middleware
    # uses core::length() for determining the content length.
    $Kernel::OM->Get('Kernel::System::Encode')->EncodeOutput( \$Output );

    # The OTOBO response object already has the HTPP headers.
    # Enhance it with the HTTP status code and the content.
    my $PlackResponse = Plack::Response->new(
        200,
        $Kernel::OM->Get('Kernel::System::Web::Response')->Headers(),
        $Output
    );

    # The exception is caught be Plack::Middleware::HTTPExceptions
    die Kernel::System::Web::Exception->new(
        PlackResponse => $PlackResponse
    );
}

# using PublicError() internally
sub PublicErrorScreen {
    my ( $Self, %Param ) = @_;

    return join '',
        $Self->CustomerHeader( Title => 'Error' ),
        $Self->PublicError(%Param),
        $Self->CustomerFooter();
}

=head2 Ascii2RichText()

converts text to rich text

    my $HTMLString = $LayoutObject->Ascii2RichText(
        String => $TextString,
    );

=cut

sub Ascii2RichText {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(String)) {
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # ascii 2 html
    $Param{String} = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToHTML(
        String => $Param{String},
    );

    return $Param{String};
}

=head2 RichText2Ascii()

converts text to rich text

    my $TextString = $LayoutObject->RichText2Ascii(
        String => $HTMLString,
    );

=cut

sub RichText2Ascii {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(String)) {
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # ascii 2 html
    $Param{String} = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToAscii(
        String => $Param{String},
    );

    return $Param{String};
}

=head2 RichTextDocumentComplete()

1) add html, body, ... tags to be a valid html document
2) replace links of inline content e. g. images to <img src="cid:xxxx" />

    $HTMLBody = $LayoutObject->RichTextDocumentComplete(
        String => $HTMLBody,
    );

=cut

sub RichTextDocumentComplete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(String)) {
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # replace image link with content id for uploaded images
    my $StringRef = $Self->_RichTextReplaceLinkOfInlineContent(
        String => \$Param{String},
    );

    # verify html document
    $Param{String} = $Kernel::OM->Get('Kernel::System::HTMLUtils')->DocumentComplete(
        String  => ${$StringRef},
        Charset => $Self->{UserCharset},
    );

    # do correct direction
    if ( $Self->{TextDirection} ) {
        $Param{String} =~ s/<body/<body dir="$Self->{TextDirection}"/i;
    }

    # filter links in response
    $Param{String} = $Self->HTMLLinkQuote( String => $Param{String} );

    return $Param{String};
}

=begin Internal:

=head2 _RichTextReplaceLinkOfInlineContent()

replace links of inline content e. g. images

    $HTMLBodyStringRef = $LayoutObject->_RichTextReplaceLinkOfInlineContent(
        String => $HTMLBodyStringRef,
    );

=cut

sub _RichTextReplaceLinkOfInlineContent {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(String)) {
        if ( !$Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # replace image link with content id for uploaded images
    ${ $Param{String} } =~ s{
        (<img.+?src=("|'))[^"'>]+?ContentID=(.+?)("|')([^>]*>)
    }
    {
        my ($Start, $CID, $Close, $End) = ($1, $3, $4, $5);
        # Make sure we only get the CID and not extra stuff like session information
        $CID =~ s{^([^;&]+).*}{$1}smx;
        $Start . 'cid:' . $CID . $Close . $End;
    }esgxi;

    return $Param{String};
}

=end Internal:

=head2 RichTextDocumentServe()

Serve a rich text (HTML) document for local view inside of an C<iframe> in correct charset and with correct links for
inline documents.

By default, all inline/active content (such as C<script>, C<object>, C<applet> or C<embed> tags) will be stripped. If
there are external images, they will be stripped too, but a message will be shown allowing the user to reload the page
showing the external images.

    my %HTMLFile = $LayoutObject->RichTextDocumentServe(
        Data => {
            Content     => $HTMLBodyRef,
            ContentType => 'text/html; charset="iso-8859-1"',
        },
        URL               => 'AgentTicketAttachment;Subaction=HTMLView;TicketID=123;ArticleID=123;FileID=',
        Attachments       => \%AttachmentListOfInlineAttachments,

        LoadInlineContent => 0,     # Serve the document including all inline content. WARNING: This might be dangerous.

        LoadExternalImages => 0,    # Load external images? If this is 0, a message will be included if
                                    # external images were found and removed.
    );

=cut

sub RichTextDocumentServe {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(Data URL Attachments)) {
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # Get charset from passed content type parameter.
    my $Charset;
    if ( $Param{Data}->{ContentType} =~ m/.+?charset=("|'|)(.+)/ig ) {
        $Charset = $2;
        $Charset =~ s/"|'//g;
    }
    if ( !$Charset ) {
        $Charset = 'us-ascii';
        $Param{Data}->{ContentType} .= '; charset="us-ascii"';
    }

    # Convert to internal charset.
    if ($Charset) {
        $Param{Data}->{Content} = $Kernel::OM->Get('Kernel::System::Encode')->Convert(
            Text  => $Param{Data}->{Content},
            From  => $Charset,
            To    => 'utf-8',
            Check => 1,
        );

        # Replace charset in content type and content.
        $Param{Data}->{ContentType} =~ s/\Q$Charset\E/utf-8/gi;
        if ( !( $Param{Data}->{Content} =~ s/(<meta[^>]+charset=("|'|))\Q$Charset\E/$1utf-8/gi ) ) {

            # Add explicit charset if missing.
            $Param{Data}->{Content}
                =~ s/(<meta [^>]+ http-equiv=("|')?Content-Type("|')? [^>]+ content=("|')?[^;"'>]+)/$1; charset=utf-8/ixms;
        }
    }

    # add html links
    $Param{Data}->{Content} = $Self->HTMLLinkQuote(
        String => $Param{Data}->{Content},
    );

    # cleanup some html tags to be cross browser compat.
    $Param{Data}->{Content} = $Self->RichTextDocumentCleanup(
        String => $Param{Data}->{Content},
    );

    # safety check
    if ( !$Param{LoadInlineContent} ) {

        # Strip out active content first, keeping external images.
        my %SafetyCheckResult = $Kernel::OM->Get('Kernel::System::HTMLUtils')->Safety(
            String       => $Param{Data}->{Content},
            NoApplet     => 1,
            NoObject     => 1,
            NoEmbed      => 1,
            NoSVG        => 1,
            NoIntSrcLoad => 0,
            NoExtSrcLoad => 0,
            NoJavaScript => 1,
            Debug        => $Self->{Debug},
        );

        $Param{Data}->{Content} = $SafetyCheckResult{String};

        if ( !$Param{LoadExternalImages} ) {

            # Strip out external content.
            my %SafetyCheckResult = $Kernel::OM->Get('Kernel::System::HTMLUtils')->Safety(
                String       => $Param{Data}->{Content},
                NoApplet     => 1,
                NoObject     => 1,
                NoEmbed      => 1,
                NoSVG        => 1,
                NoIntSrcLoad => 0,
                NoExtSrcLoad => 1,
                NoJavaScript => 1,
                Debug        => $Self->{Debug},
            );

            $Param{Data}->{Content} = $SafetyCheckResult{String};

            # Show confirmation button to load external content explicitly only if BlockLoadingRemoteContent is disabled.
            if (
                $SafetyCheckResult{Replace}
                && !$Kernel::OM->Get('Kernel::Config')->Get('Ticket::Frontend::BlockLoadingRemoteContent')
                )
            {

                # Generate blocker message.
                my $Message = $Self->Output( TemplateFile => 'AttachmentBlocker' );

                # Add it to the beginning of the body, if possible, otherwise prepend it.
                if ( $Param{Data}->{Content} =~ /<body.*?>/si ) {
                    $Param{Data}->{Content} =~ s/(<body.*?>)/$1\n$Message/si;
                }
                else {
                    $Param{Data}->{Content} = $Message . $Param{Data}->{Content};
                }
            }

        }
    }

    # build base url for inline images
    my $SessionID = '';
    if ( $Self->{SessionID} && !$Self->{SessionIDCookie} ) {
        $SessionID = ';' . $Self->{SessionName} . '=' . $Self->{SessionID};
    }

    # replace inline images in content with runtime url to images
    my $AttachmentLink = $Self->{Baselink} . $Param{URL};
    $Param{Data}->{Content} =~ s{
        (=|"|')cid:(.*?)("|'|>|\/>|\s)
    }
    {
        my $Start= $1;
        my $ContentID = $2;
        my $End = $3;

        # improve html quality
        if ( $Start ne '"' && $Start ne '\'' ) {
            $Start .= '"';
        }
        if ( $End ne '"' && $End ne '\'' ) {
            $End = '"' . $End;
        }

        # find matching attachment and replace it with runtime url to image
        ATTACHMENT_ID:
        for my $AttachmentID (  sort keys %{ $Param{Attachments} }) {
            next ATTACHMENT_ID if lc $Param{Attachments}->{$AttachmentID}->{ContentID} ne lc "<$ContentID>";
            $ContentID = $AttachmentLink . $AttachmentID . $SessionID;
            last ATTACHMENT_ID;
        }

        # return new runtime url
        $Start . $ContentID . $End;
    }egxi;

    # bug #5053
    # inline images using Content-Location as identifier instead of Content-ID even RFC2557
    # http://www.ietf.org/rfc/rfc2557.txt

    # find matching attachment and replace it with runtlime url to image
    ATTACHMENT:
    for my $AttachmentID ( sort keys %{ $Param{Attachments} } ) {
        next ATTACHMENT if !$Param{Attachments}->{$AttachmentID}->{ContentID};

        # content id cleanup
        $Param{Attachments}->{$AttachmentID}->{ContentID} =~ s/^<//;
        $Param{Attachments}->{$AttachmentID}->{ContentID} =~ s/>$//;

        next ATTACHMENT if !$Param{Attachments}->{$AttachmentID}->{ContentID};

        $Param{Data}->{Content} =~ s{
        (=|"|')(\Q$Param{Attachments}->{$AttachmentID}->{ContentID}\E)("|'|>|\/>|\s)
    }
    {
        my $Start= $1;
        my $ContentID = $2;
        my $End = $3;

        # improve html quality
        if ( $Start ne '"' && $Start ne '\'' ) {
            $Start .= '"';
        }
        if ( $End ne '"' && $End ne '\'' ) {
            $End = '"' . $End;
        }

        # return new runtime url
        $ContentID = $AttachmentLink . $AttachmentID . $SessionID;
        $Start . $ContentID . $End;
    }egxi;
    }

    return %{ $Param{Data} };
}

=head2 RichTextDocumentCleanup()

please see L<Kernel::System::HTML::Layout::DocumentCleanup()>

=cut

sub RichTextDocumentCleanup {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(String)) {
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    $Param{String} = $Kernel::OM->Get('Kernel::System::HTMLUtils')->DocumentCleanup(
        String => $Param{String},
    );

    return $Param{String};
}

=begin Internal:

=head2 _BuildSelectionOptionRefCreate()

create the option hash

    my $OptionRef = $LayoutObject->_BuildSelectionOptionRefCreate(
        %Param,
    );

    my $OptionRef = {
        Sort         => 'numeric',
        PossibleNone => 0,
        Max          => 100,
    }

=cut

sub _BuildSelectionOptionRefCreate {
    my ( $Self, %Param ) = @_;

    # set SelectedID option
    my $OptionRef = {};
    if ( defined $Param{SelectedID} ) {
        if ( ref $Param{SelectedID} eq 'ARRAY' ) {
            for my $Key ( @{ $Param{SelectedID} } ) {
                $OptionRef->{SelectedID}->{$Key} = 1;
            }
        }
        else {
            $OptionRef->{SelectedID}->{ $Param{SelectedID} } = 1;
        }
    }

    # set SelectedValue option
    if ( defined $Param{SelectedValue} ) {
        if ( ref $Param{SelectedValue} eq 'ARRAY' ) {
            for my $Value ( @{ $Param{SelectedValue} } ) {
                $OptionRef->{SelectedValue}->{$Value} = 1;
            }
        }
        else {
            $OptionRef->{SelectedValue}->{ $Param{SelectedValue} } = 1;
        }
    }

    # set Sort option
    $OptionRef->{Sort} = 0;
    if ( $Param{Sort} ) {
        $OptionRef->{Sort} = $Param{Sort};
    }

    # look if a individual sort is available
    if ( $Param{SortIndividual} && ref $Param{SortIndividual} eq 'ARRAY' ) {
        $OptionRef->{SortIndividual} = $Param{SortIndividual};
    }

    # set SortReverse option
    $OptionRef->{SortReverse} = 0;
    if ( $Param{SortReverse} ) {
        $OptionRef->{SortReverse} = 1;
    }

    # set Translation option
    $OptionRef->{Translation} = 1;
    if ( defined $Param{Translation} && $Param{Translation} eq 0 ) {
        $OptionRef->{Translation} = 0;
    }

    # correcting selected value hash if translation is on
    if (
        $OptionRef->{Translation}
        && $OptionRef->{SelectedValue}
        && ref $OptionRef->{SelectedValue} eq 'HASH'
        )
    {
        my %SelectedValueNew;
        for my $OriginalKey ( sort keys %{ $OptionRef->{SelectedValue} } ) {
            my $TranslatedKey = $Self->{LanguageObject}->Translate($OriginalKey);
            $SelectedValueNew{$TranslatedKey} = 1;
        }
        $OptionRef->{SelectedValue} = \%SelectedValueNew;
    }

    # set PossibleNone option
    $OptionRef->{PossibleNone} = 0;
    if ( $Param{PossibleNone} ) {
        $OptionRef->{PossibleNone} = 1;
    }

    # set TreeView option
    $OptionRef->{TreeView} = 0;
    if ( $Param{TreeView} ) {
        $OptionRef->{TreeView} = 1;
        $OptionRef->{Sort}     = 'TreeView';
    }

    # set DisabledBranch option
    if ( $Param{DisabledBranch} ) {
        if ( ref $Param{DisabledBranch} eq 'ARRAY' ) {
            for my $Branch ( @{ $Param{DisabledBranch} } ) {
                $OptionRef->{DisabledBranch}->{$Branch} = 1;
            }
        }
        else {
            $OptionRef->{DisabledBranch}->{ $Param{DisabledBranch} } = 1;
        }
    }

    # set Max option
    $OptionRef->{Max} = $Param{Max} || 100;

    # set HTMLQuote option
    $OptionRef->{HTMLQuote} = 1;
    if ( defined $Param{HTMLQuote} ) {
        $OptionRef->{HTMLQuote} = $Param{HTMLQuote};
    }

    return $OptionRef;
}

=head2 _BuildSelectionAttributeRefCreate()

create the attribute hash

    my $AttributeRef = $LayoutObject->_BuildSelectionAttributeRefCreate(
        %Param,
    );

    my $AttributeRef = {
        name     => 'TheName',
        multiple => undef,
        size     => 5,
    }

=cut

sub _BuildSelectionAttributeRefCreate {
    my ( $Self, %Param ) = @_;

    my $AttributeRef = {};

    # check params with key and value
    for (qw(Name ID Size Class OnChange OnClick AutoComplete)) {
        if ( $Param{$_} ) {
            $AttributeRef->{ lc($_) } = $Param{$_};
        }
    }

    # add id attriubut
    if ( !$AttributeRef->{id} ) {
        $AttributeRef->{id} = $AttributeRef->{name};
    }

    # check params with key and value that need to be HTML-Quoted
    for (qw(Title)) {
        if ( $Param{$_} ) {
            $AttributeRef->{ lc($_) } = $Self->Ascii2Html( Text => $Param{$_} );
        }
    }

    # check HTML params
    for (qw(Multiple Disabled)) {
        if ( $Param{$_} ) {
            $AttributeRef->{ lc($_) } = lc($_);
        }
    }

    return $AttributeRef;
}

=head2 _BuildSelectionDataRefCreate()

create the data hash

    my $DataRef = $LayoutObject->_BuildSelectionDataRefCreate(
        Data => $ArrayRef,              # use $HashRef, $ArrayRef or $ArrayHashRef
        AttributeRef => $AttributeRef,
        OptionRef => $OptionRef,
    );

    my $DataRef  = [
        {
            Key => 11,
            Value => 'Text',
        },
        {
            Key => 'abc',
            Value => '&nbsp;&nbsp;Text',
            Selected => 1,
        },
    ];

=cut

sub _BuildSelectionDataRefCreate {
    my ( $Self, %Param ) = @_;

    my $AttributeRef = $Param{AttributeRef};
    my $OptionRef    = $Param{OptionRef};
    my $DataRef      = [];

    my $Counter = 0;

    # for HashRef and ArrayRef only
    my %DisabledElements;

    # dclone $Param{Data} because the subroutine unfortunately modifies
    # the original data ref
    my $DataLocal = $Kernel::OM->Get('Kernel::System::Storable')->Clone( Data => $Param{Data} );

    # if HashRef was given
    if ( ref $DataLocal eq 'HASH' ) {

        # get missing parents and mark them for disable later
        if ( $OptionRef->{Sort} eq 'TreeView' ) {

            # Delete entries in hash with value = undef,
            #   because otherwise the reverse statement will cause warnings.
            # Reverse hash, skipping undefined values.
            my %List = map { $DataLocal->{$_} => $_ } grep { defined $DataLocal->{$_} } keys %{$DataLocal};

            # get each data value
            for my $Key ( sort keys %List ) {
                my $Parents = '';

                # try to split its parents (e.g. Queue or Service) GrandParent::Parent::Son
                my @Elements = split /::/, $Key;

                # get each element in the hierarchy
                for my $Element (@Elements) {

                    # add its own parents for the complete name
                    my $ElementLongName = $Parents . $Element;

                    # check if element exists in the original data or if it is already marked
                    if ( !$List{$ElementLongName} && !$DisabledElements{$ElementLongName} ) {

                        # mark element as disabled
                        $DisabledElements{$ElementLongName} = 1;

                        # add the element to the original data to be disabled later
                        $DataLocal->{ $ElementLongName . '_Disabled' } = $ElementLongName;
                    }
                    $Parents .= $Element . '::';
                }
            }
        }

        # sort hash (before the translation)
        my @SortKeys;
        if ( $OptionRef->{Sort} eq 'IndividualValue' && $OptionRef->{SortIndividual} ) {
            my %List = reverse %{$DataLocal};
            for my $Key ( @{ $OptionRef->{SortIndividual} } ) {
                if ( $List{$Key} ) {
                    push @SortKeys, $List{$Key};
                    delete $List{$Key};
                }
            }
            push @SortKeys, sort { lc $a cmp lc $b } ( values %List );
        }

        # translate value
        if ( $OptionRef->{Translation} ) {
            for my $Row ( sort keys %{$DataLocal} ) {
                $DataLocal->{$Row} = $Self->{LanguageObject}->Translate( $DataLocal->{$Row} );
            }
        }

        # sort hash (after the translation)
        if ( $OptionRef->{Sort} eq 'NumericKey' ) {
            @SortKeys = sort { $a <=> $b } ( keys %{$DataLocal} );
        }
        elsif ( $OptionRef->{Sort} eq 'NumericValue' ) {
            @SortKeys = sort { $DataLocal->{$a} <=> $DataLocal->{$b} } ( keys %{$DataLocal} );
        }
        elsif ( $OptionRef->{Sort} eq 'AlphanumericKey' ) {
            @SortKeys = sort( keys %{$DataLocal} );
        }
        elsif ( $OptionRef->{Sort} eq 'TreeView' ) {

            # add suffix for correct sorting
            my %SortHash;
            KEY:
            for my $Key ( sort keys %{$DataLocal} ) {
                next KEY if !defined $DataLocal->{$Key};
                $SortHash{$Key} = $DataLocal->{$Key} . '::';
            }
            @SortKeys = sort { lc $SortHash{$a} cmp lc $SortHash{$b} } ( keys %SortHash );
        }
        elsif ( $OptionRef->{Sort} eq 'IndividualKey' && $OptionRef->{SortIndividual} ) {
            my %List = %{$DataLocal};
            for my $Key ( @{ $OptionRef->{SortIndividual} } ) {
                if ( $List{$Key} ) {
                    push @SortKeys, $Key;
                    delete $List{$Key};
                }
            }
            push @SortKeys, sort { lc $List{$a} cmp lc $List{$b} } ( keys %List );
        }
        elsif ( $OptionRef->{Sort} eq 'IndividualValue' && $OptionRef->{SortIndividual} ) {

            # already done before the translation
        }
        else {
            @SortKeys = sort {
                lc( $DataLocal->{$a} // '' )
                    cmp lc( $DataLocal->{$b} // '' )
            } ( keys %{$DataLocal} );
            $OptionRef->{Sort} = 'AlphanumericValue';
        }

        # create DataRef
        for my $Row (@SortKeys) {
            $DataRef->[$Counter]->{Key}   = $Row;
            $DataRef->[$Counter]->{Value} = $DataLocal->{$Row};
            $Counter++;
        }
    }

    # if ArrayHashRef was given
    elsif ( ref $DataLocal eq 'ARRAY' && ref $DataLocal->[0] eq 'HASH' ) {

        # get missing parents and mark them for disable later
        if ( $OptionRef->{Sort} eq 'TreeView' ) {

            # build a list of element longnames
            my @NewDataLocal;

            my %List;
            for my $ValueHash ( @{$DataLocal} ) {
                $List{ $ValueHash->{Value} } = 1;
            }

            # get each data value hash
            for my $ValueHash ( @{$DataLocal} ) {

                my $Parents = '';

                # try to split its parents (e.g. Queue or Service) GrandParent::Parent::Son
                my @Elements = split /::/, $ValueHash->{Value};

                # get each element in the hierarchy
                for my $Element (@Elements) {

                    # add its own parents for the complete name
                    my $ElementLongName = $Parents . $Element;

                    # check if element exists in the original data or if it is already marked
                    if ( !$List{$ElementLongName} && !$DisabledElements{$ElementLongName} ) {

                        # mark element as disabled
                        $DisabledElements{$ElementLongName} = 1;

                        # push the missing element to the data local array
                        push @NewDataLocal, {
                            Key      => $ElementLongName . '_Disabled',
                            Value    => $ElementLongName,
                            Disabled => 1,
                        };
                    }
                    $Parents .= $Element . '::';
                }

                # push the element to the data local array
                push @NewDataLocal, {
                    Key      => $ValueHash->{Key},
                    Value    => $ValueHash->{Value},
                    Selected => $ValueHash->{Selected} ? 1 : 0,
                    Disabled => $ValueHash->{Disabled} ? 1 : 0,
                };
            }

            # override the data local with the new one
            @{$DataLocal} = @NewDataLocal;
        }

        # create DataRef
        for my $Row ( @{$DataLocal} ) {
            if ( ref $Row eq 'HASH' && defined $Row->{Key} ) {
                $DataRef->[$Counter]->{Key}   = $Row->{Key};
                $DataRef->[$Counter]->{Value} = $Row->{Value};

                # translate value
                if ( $OptionRef->{Translation} ) {
                    $DataRef->[$Counter]->{Value} = $Self->{LanguageObject}->Translate( $DataRef->[$Counter]->{Value} );
                }

                # set Selected and Disabled options
                if ( $Row->{Selected} ) {
                    $DataRef->[$Counter]->{Selected} = 1;
                }
                elsif ( $Row->{Disabled} ) {
                    $DataRef->[$Counter]->{Disabled} = 1;
                }
                $Counter++;
            }
        }
    }

    # if ArrayRef was given
    elsif ( ref $DataLocal eq 'ARRAY' ) {

        # get missing parents and mark them for disable later
        if ( $OptionRef->{Sort} eq 'TreeView' ) {
            my %List = map { $_ => 1 } @{$DataLocal};

            # get each data value
            for my $Key ( sort keys %List ) {
                my $Parents = '';

                # try to split its parents (e.g. Queue or Service) GrandParent::Parent::Son
                my @Elements = split /::/, $Key;

                # get each element in the hierarchy
                for my $Element (@Elements) {

                    # add its own parents for the complete name
                    my $ElementLongName = $Parents . $Element;

                    # check if element exists in the original data or if it is already marked
                    if ( !$List{$ElementLongName} && !$DisabledElements{$ElementLongName} ) {

                        # mark element as disabled
                        $DisabledElements{$ElementLongName} = 1;

                        # add the element to the original data to be disabled later
                        push @{$DataLocal}, $ElementLongName;
                    }
                    $Parents .= $Element . '::';
                }
            }
        }

        if ( $OptionRef->{Sort} eq 'IndividualValue' && $OptionRef->{SortIndividual} ) {
            my %List = map { $_ => 1 } @{$DataLocal};
            $DataLocal = [];
            for my $Key ( @{ $OptionRef->{SortIndividual} } ) {
                if ( $List{$Key} ) {
                    push @{$DataLocal}, $Key;
                    delete $List{$Key};
                }
            }
            push @{$DataLocal}, sort { $a cmp $b } ( keys %List );
        }

        my %ReverseHash;

        # translate value
        if ( $OptionRef->{Translation} ) {
            my @TranslateArray;
            for my $Row ( @{$DataLocal} ) {
                my $TranslateString = $Self->{LanguageObject}->Translate($Row);
                push @TranslateArray, $TranslateString;
                $ReverseHash{$TranslateString} = $Row;
            }
            $DataLocal = \@TranslateArray;
        }
        else {
            for my $Row ( @{$DataLocal} ) {
                $ReverseHash{$Row} = $Row;
            }
        }

        # sort array
        if ( $OptionRef->{Sort} eq 'AlphanumericKey' || $OptionRef->{Sort} eq 'AlphanumericValue' )
        {
            my @SortArray = sort( @{$DataLocal} );
            $DataLocal = \@SortArray;
        }
        elsif ( $OptionRef->{Sort} eq 'NumericKey' || $OptionRef->{Sort} eq 'NumericValue' ) {
            my @SortArray = sort { $a <=> $b } ( @{$DataLocal} );
            $DataLocal = \@SortArray;
        }
        elsif ( $OptionRef->{Sort} eq 'TreeView' ) {

            # sort array, add '::' in the comparison, for proper sort of Items with Items::SubItems
            my @SortArray = sort { $a . '::' cmp $b . '::' } @{$DataLocal};
            $DataLocal = \@SortArray;
        }

        # create DataRef
        for my $Row ( @{$DataLocal} ) {
            $DataRef->[$Counter]->{Key}   = $ReverseHash{$Row};
            $DataRef->[$Counter]->{Value} = $Row;
            $Counter++;
        }
    }

    # check disabled items on ArrayRef or HashRef only
    if (
        ref $DataLocal eq 'HASH'
        || ( ref $DataLocal eq 'ARRAY' && ref $DataLocal->[0] ne 'HASH' )
        )
    {
        for my $Row ( @{$DataRef} ) {
            if ( defined $Row->{Value} && $DisabledElements{ $Row->{Value} } ) {
                $Row->{Key}      = '-';
                $Row->{Disabled} = 1;
            }
        }
    }

    # DisabledBranch option
    if ( $OptionRef->{DisabledBranch} ) {
        for my $Row ( @{$DataRef} ) {
            for my $Branch ( sort keys %{ $OptionRef->{DisabledBranch} } ) {
                if ( $Row->{Value} =~ /^(\Q$Branch\E)$/ || $Row->{Value} =~ /^(\Q$Branch\E)::/ ) {
                    $Row->{Disabled} = 1;
                }
            }
        }
    }

    # SelectedID and SelectedValue option
    if ( defined $OptionRef->{SelectedID} || $OptionRef->{SelectedValue} ) {
        for my $Row ( @{$DataRef} ) {
            if (
                (
                    (
                        defined $Row->{Key}
                        && $OptionRef->{SelectedID}->{ $Row->{Key} }
                    )
                    ||
                    (
                        defined $Row->{Value}
                        && $OptionRef->{SelectedValue}->{ $Row->{Value} }
                    )
                )
                &&
                (
                    defined $Row->{Value}
                    && !$DisabledElements{ $Row->{Value} }
                )
                )
            {
                $Row->{Selected} = 1;
            }
        }
    }

    # SortReverse option
    if ( $OptionRef->{SortReverse} ) {
        @{$DataRef} = reverse( @{$DataRef} );
    }

    # PossibleNone option
    if ( $OptionRef->{PossibleNone} ) {
        my %None;
        $None{Key}   = '';
        $None{Value} = '-';

        unshift( @{$DataRef}, \%None );
    }

    # TreeView option
    if ( $OptionRef->{TreeView} ) {

        ROW:
        for my $Row ( @{$DataRef} ) {

            next ROW if !$Row->{Value};

            my @Fragment = split /::/, $Row->{Value};
            $Row->{Value} = pop @Fragment;

            # translate the individual tree options
            if ( $OptionRef->{Translation} ) {
                $Row->{Value} = $Self->{LanguageObject}->Translate( $Row->{Value} );
            }

            # TODO: Here we are combining Max with HTMLQuote, check below for the REMARK:
            # Max and HTMLQuote needs to be done before spaces insert but after the split of the
            # parents, then it is not possible to do it outside
            if ( $OptionRef->{HTMLQuote} ) {
                $Row->{Value} = $Self->Ascii2Html(
                    Text => $Row->{Value},
                    Max  => $OptionRef->{Max},
                );
            }
            elsif ( $OptionRef->{Max} ) {
                if ( length $Row->{Value} > $OptionRef->{Max} ) {
                    $Row->{Value} = substr( $Row->{Value}, 0, $OptionRef->{Max} - 5 ) . '[...]';
                }
            }

            # Use unicode 'NO-BREAK SPACE' since unicode characters doesn't need to be escaped.
            # Previously, we used '&nbsp;' and we had issue that Option needs to be html encoded
            # in AJAX, and it was causing issues.
            my $Space = "\xA0\xA0" x scalar @Fragment;
            $Space ||= '';

            $Row->{Value} = $Space . $Row->{Value};
        }
    }
    else {

        # HTMLQuote option
        if ( $OptionRef->{HTMLQuote} ) {
            for my $Row ( @{$DataRef} ) {
                $Row->{Key}   = $Self->Ascii2Html( Text => $Row->{Key} );
                $Row->{Value} = $Self->Ascii2Html( Text => $Row->{Value} );
            }
        }

        # TODO: Check this comment!
        # Max option
        # REMARK: Don't merge the Max handling with Ascii2Html function call of
        # the HTMLQuote handling. In this case you lose the max handling if you
        # deactivate HTMLQuote
        if ( $OptionRef->{Max} ) {

            # REMARK: This is the same solution as in Ascii2Html
            for my $Row ( @{$DataRef} ) {

                if ( ref $Row eq 'HASH' ) {
                    if ( length $Row->{Value} > $OptionRef->{Max} ) {
                        $Row->{Value} = substr( $Row->{Value}, 0, $OptionRef->{Max} - 5 ) . '[...]';
                    }
                }
                else {
                    if ( length $Row > $OptionRef->{Max} ) {
                        $Row = substr( $Row, 0, $OptionRef->{Max} - 5 ) . '[...]';
                    }
                }
            }
        }
    }

    return $DataRef;
}

=head2 _BuildSelectionOutput()

create the html string

    my $HTMLString = $LayoutObject->_BuildSelectionOutput(
        AttributeRef       => $AttributeRef,
        DataRef            => $DataRef,
        TreeView           => 0,              # optional, see BuildSelection()
        FiltersRef         => \@Filters,      # optional, see BuildSelection()
        FilterActive       => $FilterActive,  # optional, see BuildSelection()
        ExpandFilters      => 1,              # optional, see BuildSelection()
        ValidateDateAfter  => '2016-01-01',   # optional, see BuildSelection()
        ValidateDateBefore => '2016-01-01',   # optional, see BuildSelection()
    );

    my $AttributeRef = {
        name => 'TheName',
        multiple => undef,
        size => 5,
    }

    my $DataRef  = [
        {
            Key => 11,
            Value => 'Text',
            Disabled => 1,
        },
        {
            Key => 'abc',
            Value => '&nbsp;&nbsp;Text',
            Selected => 1,
        },
    ];

=cut

sub _BuildSelectionOutput {
    my ( $Self, %Param ) = @_;

    # start generation, if AttributeRef and DataRef was found
    my $String;
    if ( $Param{AttributeRef} && $Param{DataRef} ) {

        # generate <select> row
        $String = '<select';
        for my $Key ( sort keys %{ $Param{AttributeRef} } ) {
            if ( $Key && defined $Param{AttributeRef}->{$Key} ) {
                $String .= " $Key=\"$Param{AttributeRef}->{$Key}\"";
            }
            elsif ($Key) {
                $String .= " $Key";
            }
        }

        # add filters if defined
        if ( $Param{FiltersRef} && scalar @{ $Param{FiltersRef} } > 0 ) {
            my $JSON = $Self->JSONEncode(
                Data => {
                    Filters => $Param{FiltersRef},
                },
                NoQuotes => 1,
            );
            my $JSONEscaped = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToHTML(
                String => $JSON,
            );
            $String .= " data-filters=\"$JSONEscaped\"";
            if ( $Param{FilterActive} ) {
                $String .= ' data-filtered="' . int( $Param{FilterActive} ) . '"';
            }
            if ( $Param{ExpandFilters} ) {
                $String .= ' data-expand-filters="' . int( $Param{ExpandFilters} ) . '"';
            }
        }

        # tree flag for Input Fields
        if ( $Param{TreeView} ) {
            $String .= ' data-tree="true"';
        }

        # date validation values
        if ( $Param{ValidateDateAfter} ) {
            $String .= ' data-validate-date-after="' . $Param{ValidateDateAfter} . '"';
        }
        if ( $Param{ValidateDateBefore} ) {
            $String .= ' data-validate-date-before="' . $Param{ValidateDateBefore} . '"';
        }

        $String .= ">\n";

        # generate <option> rows
        for my $Row ( @{ $Param{DataRef} } ) {
            my $Key = '';
            if ( defined $Row->{Key} ) {
                $Key = $Row->{Key};
            }
            my $Value = '';
            if ( defined $Row->{Value} ) {
                $Value = $Row->{Value};
            }
            my $SelectedDisabled = '';
            if ( $Row->{Selected} ) {
                $SelectedDisabled = ' selected="selected"';
            }
            elsif ( $Row->{Disabled} ) {
                $SelectedDisabled = ' disabled="disabled"';
            }
            my $OptionTitle = '';
            if ( $Param{OptionTitle} ) {
                $OptionTitle = ' title="' . $Value . '"';
            }
            $String .= "  <option value=\"$Key\"$SelectedDisabled$OptionTitle>$Value</option>\n";
        }
        $String .= '</select>';

        if ( $Param{TreeView} ) {
            my $TreeSelectionMessage = $Self->{LanguageObject}->Translate("Show Tree Selection");
            $String
                .= ' <a href="#" title="'
                . $TreeSelectionMessage
                . '" class="ShowTreeSelection"><span>'
                . $TreeSelectionMessage . '</span><i class="fa fa-sitemap"></i></a>';
        }

    }
    return $String;
}

=end Internal:

=head2 WrapPlainText()

This sub has two main functionalities:
1. Check every line and make sure that "\n" is the ending of the line.
2. If the line does _not_ start with ">" (e.g. not cited text)
wrap it after the number of "MaxCharacters" (e.g. if MaxCharacters is "80" wrap after 80 characters).
Do this _just_ if the line, that should be wrapped, contains space characters at which the line can be wrapped.

If you need more info to understand what it does, take a look at the UnitTest WrapPlainText.t to see
use cases there.

my $WrappedPlainText = $LayoutObject->WrapPlainText(
    PlainText     => "Some Plain text that is longer than the amount stored in MaxCharacters",
    MaxCharacters => 80,
);

=cut

sub WrapPlainText {
    my ( $Self, %Param ) = @_;

    # Return if we did not get MaxCharacters
    # or MaxCharacters doesn't contain just an int
    if ( !IsPositiveInteger( $Param{MaxCharacters} ) ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Got no or invalid MaxCharacters!",
        );
        return;
    }

    # Return if we didn't get PlainText
    if ( !defined $Param{PlainText} ) {
        return;
    }

    # Return if we got no Scalar
    if ( ref $Param{PlainText} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Had no string in PlainText!",
        );
        return;
    }

    # Return PlainText if we have less than MaxCharacters
    if ( length $Param{PlainText} < $Param{MaxCharacters} ) {
        return $Param{PlainText};
    }

    my $WorkString = $Param{PlainText};

    # Normalize line endings to avoid problems with \r\n (bug#11078).
    $WorkString =~ s/\r\n?/\n/g;
    $WorkString =~ s/(^>.+|.{4,$Param{MaxCharacters}})(?:\s|\z)/$1\n/gm;
    return $WorkString;
}

=head2 SetRichTextParameters()

set properties for rich text editor and send them to JavaScript via AddJSData()

$LayoutObject->SetRichTextParameters(
    Data => \%Param,
);

=cut

sub SetRichTextParameters {
    my ( $Self, %Param ) = @_;

    $Param{Data} ||= {};

    # get and check param Data
    if ( ref $Param{Data} ne 'HASH' ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need HashRef in Param Data! Got: '" . ref( $Param{Data} ) . "'!",
        );
        $Self->FatalError();
    }

    # get needed objects
    my $LanguageObject = $Kernel::OM->Get('Kernel::Language');
    my $ConfigObject   = $Kernel::OM->Get('Kernel::Config');

    # get needed variables
    my $ScreenRichTextHeight = $Param{Data}->{RichTextHeight}              || $ConfigObject->Get("Frontend::RichTextHeight");
    my $ScreenRichTextWidth  = $Param{Data}->{RichTextWidth}               || $ConfigObject->Get("Frontend::RichTextWidth");
    my $RichTextType         = $Param{Data}->{RichTextType}                || '';
    my $PictureUploadAction  = $Param{Data}->{RichTextPictureUploadAction} || '';
    my $TextDir              = $Self->{TextDirection}                      || '';
    my $EditingAreaCSS       = 'body.cke_editable { ' . $ConfigObject->Get("Frontend::RichText::DefaultCSS") . ' }';

    # decide if we need to use the enhanced mode (with tables)
    my @Toolbar;
    my @ToolbarWithoutImage;

    if ( $RichTextType eq 'CodeMirror' ) {
        @Toolbar = @ToolbarWithoutImage = [
            [ 'autoFormat', 'CommentSelectedRange', 'UncommentSelectedRange', 'AutoComplete' ],
            [ 'Find',       'Replace',              '-',                      'SelectAll' ],
            ['Maximize'],
        ];
    }
    elsif ( $ConfigObject->Get("Frontend::RichText::EnhancedMode") == '1' ) {
        @Toolbar = [
            [
                'Bold',   'Italic',       'Underline',    'Strike',        'Subscript',    'Superscript',
                '-',      'NumberedList', 'BulletedList', 'Table',         '-',            'Outdent',
                'Indent', '-',            'JustifyLeft',  'JustifyCenter', 'JustifyRight', 'JustifyBlock',
                '-',      'Link',         'Unlink',       'Undo',          'Redo',         'SelectAll'
            ],
            '/',
            [
                'Image',   'HorizontalRule', 'PasteText', 'PasteFromWord', 'SplitQuote', 'RemoveQuote',
                '-',       '-',            'Find', 'Replace',    'TextColor',
                'BGColor', 'RemoveFormat', '-',    'ShowBlocks', 'Source', 'SpecialChar',
                '-',       'Maximize'
            ],
            [ 'Format', 'Font', 'FontSize' ]
        ];
        @ToolbarWithoutImage = [
            [
                'Bold',   'Italic',       'Underline',    'Strike',        'Subscript',    'Superscript',
                '-',      'NumberedList', 'BulletedList', 'Table',         '-',            'Outdent',
                'Indent', '-',            'JustifyLeft',  'JustifyCenter', 'JustifyRight', 'JustifyBlock',
                '-',      'Link',         'Unlink',       'Undo',          'Redo',         'SelectAll'
            ],
            '/',
            [
                'HorizontalRule', 'PasteText', 'PasteFromWord', 'SplitQuote', 'RemoveQuote', '-',
                '-',            'Find', 'Replace',    'TextColor', 'BGColor',
                'RemoveFormat', '-',    'ShowBlocks', 'Source',    'SpecialChar', '-',
                'Maximize'
            ],
            [ 'Format', 'Font', 'FontSize' ]
        ];
    }
    else {
        @Toolbar = [
            [
                'Bold',          'Italic',       'Underline',      'Strike', '-',    'NumberedList',
                'BulletedList',  '-',            'Outdent',        'Indent', '-',    'JustifyLeft',
                'JustifyCenter', 'JustifyRight', 'JustifyBlock',   '-',      'Link', 'Unlink',
                '-',             'Image',        'HorizontalRule', '-',      'Undo', 'Redo',
                '-',             'Find'
            ],
            '/',
            [
                'Format',       'Font', 'FontSize', '-',           'TextColor',  'BGColor',
                'RemoveFormat', '-',    'Source',   'SpecialChar', 'SplitQuote', 'RemoveQuote',
                '-',            'Maximize'
            ]
        ];
        @ToolbarWithoutImage = [
            [
                'Bold',          'Italic',       'Underline',    'Strike',
                '-',             'NumberedList', 'BulletedList', '-',
                'Outdent',       'Indent',       '-',            'JustifyLeft',
                'JustifyCenter', 'JustifyRight', 'JustifyBlock', '-',
                'Link',          'Unlink',       '-',            'HorizontalRule',
                '-',             'Undo',         'Redo',         '-',
                'Find'
            ],
            '/',
            [
                'Format',       'Font', 'FontSize', '-',           'TextColor',  'BGColor',
                'RemoveFormat', '-',    'Source',   'SpecialChar', 'SplitQuote', 'RemoveQuote',
                '-',            'Maximize'
            ]
        ];
    }

    # set data with AddJSData()
    $Self->AddJSData(
        Key   => 'RichText',
        Value => {
            Height         => $ScreenRichTextHeight,
            Width          => $ScreenRichTextWidth,
            TextDir        => $TextDir,
            EditingAreaCSS => $EditingAreaCSS,
            Lang           => {
                SplitQuote  => $LanguageObject->Translate('Split Quote'),
                RemoveQuote => $LanguageObject->Translate('Remove Quote'),
            },
            Toolbar             => $Toolbar[0],
            ToolbarWithoutImage => $ToolbarWithoutImage[0],
            PictureUploadAction => $PictureUploadAction,
            Type                => $RichTextType,
        },
    );

    return 1;
}

=head2 CustomerSetRichTextParameters()

set properties for customer rich text editor and send them to JavaScript via AddJSData()

$LayoutObject->CustomerSetRichTextParameters(
    Data => \%Param,
);

=cut

sub CustomerSetRichTextParameters {
    my ( $Self, %Param ) = @_;

    $Param{Data} ||= {};

    # get and check param Data
    if ( ref $Param{Data} ne 'HASH' ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need HashRef in Param Data! Got: '" . ref( $Param{Data} ) . "'!",
        );
        $Self->FatalError();
    }

    # get needed objects
    my $LanguageObject = $Kernel::OM->Get('Kernel::Language');
    my $ConfigObject   = $Kernel::OM->Get('Kernel::Config');

    my $ScreenRichTextHeight = $ConfigObject->Get("Frontend::RichTextHeight");
    my $ScreenRichTextWidth  = $ConfigObject->Get("Frontend::RichTextWidth");
    my $TextDir              = $Self->{TextDirection}                      || '';
    my $PictureUploadAction  = $Param{Data}->{RichTextPictureUploadAction} || '';
    my $EditingAreaCSS       = 'body { ' . $ConfigObject->Get("Frontend::RichText::DefaultCSS") . ' }';

    # decide if we need to use the enhanced mode (with tables)
    my @Toolbar;
    my @ToolbarWithoutImage;
    my @ToolbarMidi;
    my @ToolbarMini;

    if ( $ConfigObject->Get("Frontend::RichText::EnhancedMode::Customer") == '1' ) {
        @Toolbar = [
            [
                'Bold',   'Italic',       'Underline',    'Strike',        'Subscript',    'Superscript',
                '-',      'NumberedList', 'BulletedList', 'Table',         '-',            'Outdent',
                'Indent', '-',            'JustifyLeft',  'JustifyCenter', 'JustifyRight', 'JustifyBlock',
                '-',      'Link',         'Unlink',       'Undo',          'Redo',         'SelectAll'
            ],
            '/',
            [
                'Image',   'HorizontalRule', 'PasteText', 'PasteFromWord', 'SplitQuote', 'RemoveQuote',
                '-',       '-',            'Find', 'Replace',    'TextColor',
                'BGColor', 'RemoveFormat', '-',    'ShowBlocks', 'Source', 'SpecialChar',
                '-',       'Maximize'
            ],
            [ 'Format', 'Font', 'FontSize' ]
        ];
        @ToolbarWithoutImage = [
            [
                'Bold',   'Italic',       'Underline',    'Strike',        'Subscript',    'Superscript',
                '-',      'NumberedList', 'BulletedList', 'Table',         '-',            'Outdent',
                'Indent', '-',            'JustifyLeft',  'JustifyCenter', 'JustifyRight', 'JustifyBlock',
                '-',      'Link',         'Unlink',       'Undo',          'Redo',         'SelectAll'
            ],
            '/',
            [
                'HorizontalRule', 'PasteText', 'PasteFromWord', 'SplitQuote', 'RemoveQuote', '-',
                '-',            'Find', 'Replace',    'TextColor', 'BGColor',
                'RemoveFormat', '-',    'ShowBlocks', 'Source',    'SpecialChar', '-',
                'Maximize'
            ],
            [ 'Format', 'Font', 'FontSize' ]
        ];
    }
    else {
        @Toolbar = [
            [
                'Bold',          'Italic',       'Underline',      'Strike', '-',    'NumberedList',
                'BulletedList',  '-',            'Outdent',        'Indent', '-',    'JustifyLeft',
                'JustifyCenter', 'JustifyRight', 'JustifyBlock',   '-',      'Link', 'Unlink',
                '-',             'Image',        'HorizontalRule', '-',      'Undo', 'Redo',
                '-',             'Find'
            ],
            '/',
            [
                'Format',       'Font', 'FontSize', '-',           'TextColor',  'BGColor',
                'RemoveFormat', '-',    'Source',   'SpecialChar', 'SplitQuote', 'RemoveQuote',
                '-',            'Maximize'
            ]
        ];
        @ToolbarWithoutImage = [
            [
                'Bold',          'Italic',       'Underline',    'Strike',
                '-',             'NumberedList', 'BulletedList', '-',
                'Outdent',       'Indent',       '-',            'JustifyLeft',
                'JustifyCenter', 'JustifyRight', 'JustifyBlock', '-',
                'Link',          'Unlink',       '-',            'HorizontalRule',
                '-',             'Undo',         'Redo',         '-',
                'Find'
            ],
            '/',
            [
                'Format',       'Font', 'FontSize', '-',           'TextColor',  'BGColor',
                'RemoveFormat', '-',    'Source',   'SpecialChar', 'SplitQuote', 'RemoveQuote',
                '-',            'Maximize'
            ]
        ];
        @ToolbarMidi = [
            [
                'Bold',         'Italic', 'Underline', 'Strike', '-', 'NumberedList',
                'BulletedList', '-',      'Link',      'Unlink', '-', 'HorizontalRule',
                '-',            'Undo',   'Redo',      '-',      'Maximize'
            ],
            '/',
            [
                'FontSize', '-',           'TextColor',  'BGColor', 'RemoveFormat',
                '-',        'SpecialChar', 'SplitQuote', 'RemoveQuote',
            ]
        ];
        @ToolbarMini = [
            [
                'Bold', 'Italic', 'Underline', 'Strike', '-',    'BulletedList',
                '-',    'Link',   'Unlink',    '-',      'Undo', 'Redo',
            ],
            '/',
            [
                'FontSize', '-', 'TextColor', 'RemoveFormat', '-', 'SplitQuote', 'RemoveQuote',
            ]
        ];
    }

    # set data with AddJSData()
    $Self->AddJSData(
        Key   => 'RichText',
        Value => {
            Height         => $ScreenRichTextHeight,
            Width          => $ScreenRichTextWidth,
            TextDir        => $TextDir,
            EditingAreaCSS => $EditingAreaCSS,
            Lang           => {
                SplitQuote => $LanguageObject->Translate('Split Quote'),
            },
            Toolbar             => $Toolbar[0],
            ToolbarWithoutImage => $ToolbarWithoutImage[0],
            ToolbarMidi         => $ToolbarMidi[0],
            ToolbarMini         => $ToolbarMini[0],
            PictureUploadAction => $PictureUploadAction,
        },
    );

    return 1;
}

=head2 UserInitialsGet()

Get initials from a full name of a user.

    my $UserInitials = $LayoutObject->UserInitialsGet(
        Fullname => 'John Doe',
    );

Returns string of exactly two uppercase characters that represent user initials:

    $UserInitials = 'JD';

Please note that this function will return 'O' if invalid name (without any word characters) was supplied.

=cut

sub UserInitialsGet {
    my ( $Self, %Param ) = @_;

    # Fallback in case name is invalid.
    my $UserInitials = 'O';
    return $UserInitials if !$Param{Fullname};

    # Remove anything found in brackets (email address, etc).
    my $Fullname = $Param{Fullname} =~ s/[<[{(].*[>\]})]//r;

    # Trim whitespaces.
    $Fullname =~ s/^\s+|\s+$//g;

    # Split full name by whitespace.
    my @UserNames = split /\s+/, $Fullname;
    if (@UserNames) {

        # Cleanup unnecessary characters.
        my $FirstName = $UserNames[0] =~ s/\W//gr;
        return $UserInitials if !$FirstName;

        # Get first character of first name.
        $UserInitials = uc substr $FirstName, 0, 1;

        if ( @UserNames > 1 ) {

            # Cleanup unnecessary characters.
            my $LastName = $UserNames[-1] =~ s/\W//gr;
            return $UserInitials if !$LastName;

            # Get first character of last name.
            $UserInitials .= uc substr $LastName, 0, 1;
        }
    }

    return $UserInitials;
}

=head2 SetCookie()

Set a cookie using the syntax of Kernel/System/Request.pm

    $ResponseObject->SetCookie(
        Key      => 'ID',        # name
        Value    => 123456,      # value
        Expires  => '+3660s',    # expires
        Path     => 'otobo/',    # path optional, only allow cookie for given path, '/' will be prepended
        Secure   => 1,           # secure optional, set secure attribute to disable cookie on HTTP (HTTPS only), default is off
        HTTPOnly => 1,           # httponly optional, sets HttpOnly attribute of cookie to prevent access via JavaScript, default is off
    );

=cut

sub SetCookie {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw/Key/) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed",
            );

            return;
        }
    }

    $Self->{SetCookies}->{ $Param{Key} } = {
        name     => $Param{Key},
        value    => $Param{Value},
        expires  => $Param{Expires},
        secure   => $Param{Secure}   || '',
        httponly => $Param{HTTPOnly} || '',
        path     => '/' . ( $Param{Path} // '' ),
    };

    return 1;
}

1;
