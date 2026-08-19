import Foundation

/// The declared-intent model for `Source/anglesite.json` (#1169) — what the app has actually
/// applied to a site's domain, DNS, edge hardening, email, and Workers configuration. Every
/// field is optional except ``version``: an absent file means "no declarations," and each
/// section is only present once something has actually written to it. See the investigation
/// doc (`docs/superpowers/specs/2026-07-31-domain-config-in-git-investigation.md` §5.2) for the
/// schema rationale and the explicit exclusions (secrets, tokens, account/zone/resource IDs,
/// and unmanaged pre-existing DNS records never appear here).
///
/// This type only models the data; ``DomainConfigStore`` owns reading and writing
/// `anglesite.json` itself, including preserving keys this version of the app doesn't know
/// about (git is the source of truth — hand edits and future schema fields must survive a
/// round trip through an app that predates them).
public struct DomainConfig: Equatable, Sendable {
    /// The schema version. Always written; tolerated as absent on read (defaults to `1`) so a
    /// file hand-authored before this field existed still loads.
    public var version: Int
    public var domain: Domain?
    public var dns: DNS?
    public var edge: Edge?
    public var email: Email?
    public var workers: Workers?
    public var experiments: Experiments?
    /// The publish destination this site uses (#1015) — an open string (not a closed `enum`),
    /// matching `Domain.choice`'s precedent, so an unrecognized future value degrades gracefully
    /// for a reader that predates it. `nil` means "cloudflare," the only target that exists today
    /// — nothing reads this field to select a `DeployTarget` conformer yet (that's a later
    /// slice); it exists so that slice needs no schema migration when it lands.
    public var deployTarget: String?
    /// The dedicated public repo a `GitHubPagesDeployTarget` publishes built output to (#1015
    /// slice 2a) — always a separate repo from wherever `Source/` itself might be backed up, so
    /// choosing GitHub Pages never forces the site's source history public. `nil` until a
    /// GitHub Pages deploy target has created (or been pointed at) one.
    public var githubPages: GitHubPages?

    public init(
        version: Int = 1,
        domain: Domain? = nil,
        dns: DNS? = nil,
        edge: Edge? = nil,
        email: Email? = nil,
        workers: Workers? = nil,
        experiments: Experiments? = nil,
        deployTarget: String? = nil,
        githubPages: GitHubPages? = nil
    ) {
        self.version = version
        self.domain = domain
        self.dns = dns
        self.edge = edge
        self.email = email
        self.workers = workers
        self.experiments = experiments
        self.deployTarget = deployTarget
        self.githubPages = githubPages
    }

    /// The owner's declared hostname and attachment intent — replaces the `DOMAIN`/`DOMAIN_CHOICE`
    /// precedence dance in `.site-config` (see `SiteConfigFile`).
    public struct Domain: Codable, Equatable, Sendable {
        public var hostname: String?
        /// `"buy" | "transfer" | "later"` — kept as an open string (not a closed `enum`) so an
        /// unrecognized value from a future app version or a hand edit degrades gracefully for
        /// the reader instead of failing the whole document to decode.
        public var choice: String?
        public var attach: Bool?
        /// The domain's registrar name, from an RDAP lookup (`RDAPClient`, #1194). `nil` until a
        /// lookup has succeeded at least once.
        public var registrar: String?
        /// The domain's expiration date, as the raw ISO 8601 `eventDate` string RDAP returned —
        /// unparsed, like every other value in this struct; callers format it for display.
        public var expiresAt: String?

        public init(
            hostname: String? = nil, choice: String? = nil, attach: Bool? = nil,
            registrar: String? = nil, expiresAt: String? = nil
        ) {
            self.hostname = hostname
            self.choice = choice
            self.attach = attach
            self.registrar = registrar
            self.expiresAt = expiresAt
        }
    }

    /// DNS records the app created and therefore owns — never a mirror of the owner's whole
    /// zone (investigation doc §5.2/§5.3).
    public struct DNS: Codable, Equatable, Sendable {
        public var managedRecords: [DNSRecord]?

        public init(managedRecords: [DNSRecord]? = nil) {
            self.managedRecords = managedRecords
        }
    }

    /// One app-managed DNS record. `purpose` mirrors the `comment` tag the app stamps on the
    /// live Cloudflare record (e.g. `"email:icloud"`, `"verification:bluesky"`) so declared and
    /// live records can be joined during reconciliation (§5.3).
    public struct DNSRecord: Codable, Equatable, Sendable {
        public var type: String
        public var name: String
        public var content: String
        public var priority: Int?
        public var purpose: String?

        public init(type: String, name: String, content: String, priority: Int? = nil, purpose: String? = nil) {
            self.type = type
            self.name = name
            self.content = content
            self.priority = priority
            self.purpose = purpose
        }
    }

    /// The applied edge-hardening posture — provider-agnostic knobs at this level, Cloudflare-only
    /// ones under ``cloudflare``. Per the owner decision (investigation doc §7.2), this always
    /// serializes exactly the plan the app applied, never an aspirational target.
    public struct Edge: Codable, Equatable, Sendable {
        public var dnssec: Bool?
        public var alwaysUseHTTPS: Bool?
        public var hsts: HSTS?
        public var cloudflare: CloudflareEdge?

        public init(dnssec: Bool? = nil, alwaysUseHTTPS: Bool? = nil, hsts: HSTS? = nil, cloudflare: CloudflareEdge? = nil) {
            self.dnssec = dnssec
            self.alwaysUseHTTPS = alwaysUseHTTPS
            self.hsts = hsts
            self.cloudflare = cloudflare
        }

        public struct HSTS: Codable, Equatable, Sendable {
            public var maxAge: Int?
            public var includeSubdomains: Bool?
            public var preload: Bool?

            public init(maxAge: Int? = nil, includeSubdomains: Bool? = nil, preload: Bool? = nil) {
                self.maxAge = maxAge
                self.includeSubdomains = includeSubdomains
                self.preload = preload
            }
        }

        public struct CloudflareEdge: Codable, Equatable, Sendable {
            public var botFightMode: Bool?
            public var wafRules: [WAFRule]?

            public init(botFightMode: Bool? = nil, wafRules: [WAFRule]? = nil) {
                self.botFightMode = botFightMode
                self.wafRules = wafRules
            }
        }

        /// One Cloudflare WAF custom rule the app applied. Cloudflare-shaped by design —
        /// `cloudflare` is the only provider-specific pocket in the schema (§5.2).
        public struct WAFRule: Codable, Equatable, Sendable {
            public var description: String
            public var expression: String
            public var action: String

            public init(description: String, expression: String, action: String) {
                self.description = description
                self.expression = expression
                self.action = action
            }
        }
    }

    public struct Email: Codable, Equatable, Sendable {
        public var provider: String?
        public var dmarcReportEmail: String?
        /// The owner's email address for `/inbox` forwarding (#1570, `WorkerComposition`'s
        /// `inboxForwardEmail`) — deliberately a separate field from `dmarcReportEmail` rather
        /// than reusing it: a DMARC aggregate-report mailbox is often monitored differently
        /// (automated tooling, a different person) than where the owner wants forwarded visitor
        /// contact messages to land, and defaulting one from the other would be a silent
        /// behavior change for any site that already had `dmarcReportEmail` set for its original
        /// purpose. `nil` (the default) means "no forwarding configured" even when
        /// `dmarcReportEmail` is set — `PlistEditorModel.saveInboxForwardEmail` is the only
        /// writer, so forwarding only ever turns on when the owner explicitly opts in.
        public var inboxForwardAddress: String?

        public init(provider: String? = nil, dmarcReportEmail: String? = nil, inboxForwardAddress: String? = nil) {
            self.provider = provider
            self.dmarcReportEmail = dmarcReportEmail
            self.inboxForwardAddress = inboxForwardAddress
        }
    }

    /// The dedicated public repo backing a GitHub Pages deploy target (#1015 slice 2a). Never the
    /// same repo as any `Source/` backup — see the field-level doc comment on `DomainConfig
    /// .githubPages` above for why.
    public struct GitHubPages: Codable, Equatable, Sendable {
        public var owner: String?
        public var repo: String?

        public init(owner: String? = nil, repo: String? = nil) {
            self.owner = owner
            self.repo = repo
        }
    }

    /// The owner's active Worker set — moves out of `Config/settings.plist.activeWorkerIDs` in a
    /// later slice (#1172); this slice only models the shape.
    public struct Workers: Codable, Equatable, Sendable {
        public var active: [String]?

        public init(active: [String]? = nil) {
            self.active = active
        }
    }

    /// The site's A/B experiments (#1270 design doc §2) — git-canonical *declared intent*: what
    /// the deployed site serves. Live tallies and concluded-experiment outcomes are never
    /// declared here (they live in D1 and `Config/experiment-history.json` respectively); see the
    /// design doc's "Why git-canonical" section.
    public struct Experiments: Codable, Equatable, Sendable {
        /// v1 supports one active experiment at a time (pre-deploy-gate enforced, not here); the
        /// array leaves room to relax that later without a schema break.
        public var active: [Experiment]?

        public init(active: [Experiment]? = nil) {
            self.active = active
        }

        /// One declared experiment: a control page, a built variant page, a goal, and a
        /// lifecycle status. Mirrors the template's `AnglesiteExperiment` TypeScript interface
        /// (`Resources/Template/scripts/anglesite-config.ts`) field-for-field.
        public struct Experiment: Codable, Equatable, Sendable {
            /// Stable, `[A-Za-z0-9-]+` — the cookie name and D1 key.
            public var id: String
            /// Owner-facing display name.
            public var name: String
            /// The route under test; the control serves it as-is.
            public var page: String
            public var variant: Variant
            /// Control's traffic share; the app always writes `0.5`.
            public var split: Double
            public var goal: Goal
            /// `"draft" | "running"` — kept as an open string, not a closed `enum`, matching
            /// ``DomainConfig/Domain/choice`` so an unrecognized future status degrades
            /// gracefully instead of failing the whole document to decode.
            public var status: String
            /// ISO date the experiment started, driving the 30-day rule of thumb. `nil` while
            /// `status` is `"draft"`.
            public var startedAt: String?

            public init(
                id: String, name: String, page: String, variant: Variant, split: Double,
                goal: Goal, status: String, startedAt: String? = nil
            ) {
                self.id = id
                self.name = name
                self.page = page
                self.variant = variant
                self.split = split
                self.goal = goal
                self.status = status
                self.startedAt = startedAt
            }

            public struct Variant: Codable, Equatable, Sendable {
                public var id: String
                public var name: String
                /// The variant's built route.
                public var page: String

                public init(id: String, name: String, page: String) {
                    self.id = id
                    self.name = name
                    self.page = page
                }
            }

            /// `"pageview" | "route" | "scroll" | "visible"` — kept as an open `kind` string for
            /// the same forward-compatibility reason as ``status``.
            public struct Goal: Codable, Equatable, Sendable {
                public var kind: String
                /// Required for `"pageview"`/`"route"` goals.
                public var path: String?
                /// Required for `"scroll"` goals: 1-100, percent of page scrolled.
                public var depth: Int?
                /// Required for `"visible"` goals: CSS selector of the observed element.
                public var selector: String?

                public init(kind: String, path: String? = nil, depth: Int? = nil, selector: String? = nil) {
                    self.kind = kind
                    self.path = path
                    self.depth = depth
                    self.selector = selector
                }
            }
        }
    }
}

extension DomainConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, domain, dns, edge, email, workers, experiments, deployTarget, githubPages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        domain = try container.decodeIfPresent(Domain.self, forKey: .domain)
        dns = try container.decodeIfPresent(DNS.self, forKey: .dns)
        edge = try container.decodeIfPresent(Edge.self, forKey: .edge)
        email = try container.decodeIfPresent(Email.self, forKey: .email)
        workers = try container.decodeIfPresent(Workers.self, forKey: .workers)
        experiments = try container.decodeIfPresent(Experiments.self, forKey: .experiments)
        deployTarget = try container.decodeIfPresent(String.self, forKey: .deployTarget)
        githubPages = try container.decodeIfPresent(GitHubPages.self, forKey: .githubPages)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encodeIfPresent(edge, forKey: .edge)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(workers, forKey: .workers)
        try container.encodeIfPresent(experiments, forKey: .experiments)
        try container.encodeIfPresent(deployTarget, forKey: .deployTarget)
        try container.encodeIfPresent(githubPages, forKey: .githubPages)
    }
}
