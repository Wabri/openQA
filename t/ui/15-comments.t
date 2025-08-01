#!/usr/bin/env perl
# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -base, -signatures;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Log qw(log_debug);
use OpenQA::Test::TimeLimit '37';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database::generate_schema_name;
my $schema
  = $test_case->init_data(schema_name => $schema_name, fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');
my $comments = $schema->resultset('Comments');

my $t = Test::Mojo->new('OpenQA::WebAPI');

# create a parent group
$schema->resultset('JobGroupParents')->create({id => 1, name => 'Test parent', sort_order => 0});
$schema->resultset('Bugs')->create(
    {
        bugid => 'bsc#1234',
        title => 'some title with "quotes" and <html>elements</html>',
        existing => 1,
        refreshed => 1,
    });

driver_missing unless my $driver = call_driver;
disable_timeout;
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

#
# List with no parameters
#
$driver->title_is('openQA', 'on main page');
$driver->find_element_by_link_text('Login')->click();

# we are back on the main page
$driver->title_is('openQA', 'back on main page');

# check 'reviewed' labels

$t->get_ok('/dashboard_build_results?limit_builds=10')->status_is(200)
  ->element_count_is('.review', 2, 'exactly two builds marked as \'reviewed\'')
  ->element_exists('.badge-all-passed', 'one build is marked as \'reviewed-all-passed\' because all tests passed');

$driver->find_element_by_link_text('opensuse')->click();

is($driver->find_element('h2:first-of-type')->get_text(), 'Last Builds for opensuse', 'on group overview');

# define test message
my $test_message = 'This is a cool test ☠';
my $another_test_message = ' - this message will be appended if editing works ☠';
my $edited_test_message = $test_message . $another_test_message;
my $description_test_message = 'pinned-description ... The description';
my $user_name = 'Demo';

# fills out the comment form and submits
my $max_write_attempts = $ENV{OPENQA_COMMENTS_TEST_MAX_WRITE_ATTEMPTS} // 10;

sub write_comment ($text, $desc) {
    for (my $attempts = 1;; ++$attempts) {
        eval {
            wait_for_element(
                selector => '#commentForm textarea[name="text"]',
                is_displayed => 1,
                description => 'comment form is displayed'
            )->send_keys($text);
            $driver->find_element_by_id('submitComment')->click;
            wait_for_ajax msg => $desc;
        };
        return undef unless my $error = $@;
        die $error if ($error !~ qr/unexpected alert/i) || ($attempts >= $max_write_attempts);   # uncoverable statement

        # try to dismiss the alert "The comment text mustn't be empty." that is for some reason possibly shown
        # note: Even waiting until document.forms.commentForm.text.value is not empty anymore before submitting
        #       the form does not help so the retry is the best we can do (see poo#129946 for details).
        $driver->dismiss_alert;    # uncoverable statement
        $driver->execute_script('document.forms.commentForm.text.value = ""');    # uncoverable statement
    }
}

# switches to comments tab (required when editing comments in test results)
# expects the current number of comments as argument (currently the easiest way to find the tab button)
sub switch_to_comments_tab {
    my $current_comment_count = shift;
    $driver->find_element_by_link_text("Comments ($current_comment_count)")->click();
}

# checks comment heading and text for recently added comment
sub check_comment {
    my ($supposed_text, $edited) = @_;

    ok(javascript_console_has_no_warnings_or_errors(), 'no unexpected js warnings');

    # check number of elements
    my @comment_headings = $driver->find_elements('h4.media-heading');
    my @comment_bodies = $driver->find_elements('div.media-comment');
    is(scalar @comment_headings, 1, 'exactly one comment heading present');
    is(scalar @comment_bodies, 1, 'exactly one comment body present');

    # check heading
    my $first_heading_text = $comment_headings[0]->get_text();
    if ($edited) {
        is($first_heading_text, "$user_name wrote less than a minute ago (last edited less than a minute ago)",
            'heading text');
    }
    else {
        is($first_heading_text, "$user_name wrote less than a minute ago", 'heading text');
    }

    # check body
    is($comment_bodies[0]->get_text(), $supposed_text, 'body text');

    # check anchor
    my $anchor = $driver->find_child_element($comment_headings[0], '.comment-anchor')->get_attribute('href');
    $anchor =~ s/[^#]*#/#/;
    like($anchor, qr/#comment-[0-9]+/, 'anchor matches expected format');
    is($driver->find_element("$anchor div.media-comment")->get_text(), $supposed_text, 'body found via anchor ref');
}

# tests adding, editing and removing comments
sub test_comment_editing {
    my ($in_test_results) = @_;

    my $context = $in_test_results ? 'job' : 'group';
    my @comments = $driver->find_elements('div.media-comment', 'css');
    is(scalar @comments, 0, 'no comments present so far');

    subtest 'add' => sub {
        write_comment $test_message, "comment added to $context";
        switch_to_comments_tab 1 if $in_test_results;
        check_comment $test_message, 0;
    };

    subtest 'edit' => sub {
        $driver->find_element('button.trigger-edit-button')->click();
        # wait 1 second to ensure initial time and last update time differ
        sleep 1;

        # try to edit the first displayed comment (the one which has just been added)
        $driver->find_element('textarea.comment-editing-control')->send_keys($another_test_message);
        $driver->find_element('button.comment-editing-control')->click();
        wait_for_ajax(msg => 'comment updated within ' . $context);

        if ($in_test_results) {
            switch_to_comments_tab(1);
        }

        # check whether the changeings have been applied
        check_comment($edited_test_message, 1);
    };

    subtest 'remove' => sub {
        # try to remove the first displayed comment (the one which has just been edited)
        $driver->find_element('button.remove-edit-button')->click();

        # check confirmation and dismiss in the first place
        $driver->alert_text_is('Do you really want to delete the comment written by Demo?');
        $driver->dismiss_alert;
        wait_for_ajax(msg => 'comment removal dismissed within ' . $context);

        # the comment mustn't be deleted yet
        is($driver->find_element('div.media-comment')->get_text(),
            $edited_test_message, 'comment is still there after dismissing removal');

        # try to remove the first displayed comment again (and accept this time);
        $driver->find_element('button.remove-edit-button')->click();
        $driver->alert_text_is('Do you really want to delete the comment written by Demo?');
        $driver->accept_alert;
        wait_for_ajax(msg => 'comment removed within ' . $context);

        # check whether the comment is gone
        my @comments = $driver->find_elements('div.media-comment', 'css');
        is(scalar @comments, 0, 'removed comment is actually gone');

        # check whether the counter in the comments tab has been decreased to zero
        switch_to_comments_tab(0) if ($in_test_results);

        ok(javascript_console_has_no_warnings_or_errors(), 'no unexpected js warnings');

        # re-add a comment with the original message and check whether it is displayed correctly
        write_comment $test_message, "comment added to $context";
        switch_to_comments_tab 1 if $in_test_results;
        check_comment $test_message, 0;
    };
}

subtest 'commenting in the group overview' => sub {
    test_comment_editing(0);
};

subtest 'URL auto-replace' => sub {
    my $build_url = $driver->get_current_url();
    $build_url =~ s/\?.*//;
    log_debug('build_url: ' . $build_url);
    my $text = <<'EOF';
foo@bar foo#bar should not be detected as bugref
bsc#2436346bla should not be detected, too
bsc#2436347bla2
<a href="https://openqa.example.com/foo/bar">https://openqa.example.com/foo/bar</a>: http://localhost:9562
https://openqa.example.com/tests/181148 (reference http://localhost/foo/bar )
bsc#1234 boo#2345,poo#3456 t#4567 "some quotes suff should not cause problems"
t#5678/modules/welcome/steps/1
https://progress.opensuse.org/issues/6789
https://bugzilla.novell.com/show_bug.cgi?id=7890
[bsc#1000629](https://bugzilla.suse.com/show_bug.cgi?id=1000629)
<a href="https://bugzilla.suse.com/show_bug.cgi?id=1000630">bsc#1000630</a>
bnc#1246
gh#os-autoinst/openQA#1234
https://github.com/os-autoinst/os-autoinst/pull/960
bgo#768954 brc#1401123
https://bugzilla.gnome.org/show_bug.cgi?id=690345
https://bugzilla.redhat.com/show_bug.cgi?id=343098
[bsc#1043970](https://bugzilla.suse.com/show_bug.cgi?id=1043970 "Bugref at end of title: bsc#1043760")
EOF
    write_comment $text, 'comment with URL-replacing added';

    # the first made comment needs to be 2nd now
    my @comments = $driver->find_elements('div.media-comment p', 'css');
    #is($comments[0]->get_text(), $test_message, 'body of first comment after adding another');

    # uses ( delimiter for qr as there are / in the text
    like($comments[0]->get_text(),
qr(bsc#1234  boo#2345, poo#3456 t#4567 .*poo#6789  bsc#7890 bsc#1000629 bsc#1000630  bnc#1246  gh#os-autoinst/openQA#1234  gh#os-autoinst/os-autoinst#960  bgo#768954  brc#1401123)
    );
    my @urls = $driver->find_elements('div.media-comment a', 'css');
    is(scalar @urls, 19);
    is((shift @urls)->get_text(), 'http://localhost:9562', 'url2');
    is((shift @urls)->get_text(), 'https://openqa.example.com/tests/181148', 'url3');
    is((shift @urls)->get_text(), 'http://localhost/foo/bar', 'url4');
    is((shift @urls)->get_text(), ' bsc#1234', 'url5');
    is((shift @urls)->get_text(), ' boo#2345', 'url6');
    is((shift @urls)->get_text(), ' poo#3456', 'url7');
    is((shift @urls)->get_text(), 't#4567', 'url8');
    is((shift @urls)->get_text(), 't#5678/modules/welcome/steps/1', 'url9');
    is((shift @urls)->get_text(), ' poo#6789', 'url10');
    is((shift @urls)->get_text(), ' bsc#7890', 'url11');
    is((shift @urls)->get_text(), 'bsc#1000629', 'url12');
    is((shift @urls)->get_text(), ' bnc#1246', 'url14');
    is((shift @urls)->get_text(), ' gh#os-autoinst/openQA#1234', 'url15');
    is((shift @urls)->get_text(), ' gh#os-autoinst/os-autoinst#960', 'url16');
    is((shift @urls)->get_text(), ' bgo#768954', 'url17');
    is((shift @urls)->get_text(), ' brc#1401123', 'url18');
    is((shift @urls)->get_text(), ' bgo#690345', 'url19');
    is((shift @urls)->get_text(), ' brc#343098', 'url20');
    is((shift @urls)->get_text(), 'bsc#1043970', 'url21');

    my @urls2 = $driver->find_elements('div.media-comment a', 'css');
    like((shift @urls2)->get_attribute('href'), qr|^http://localhost:9562/?$|, 'url2-href');
    is((shift @urls2)->get_attribute('href'), 'https://openqa.example.com/tests/181148', 'url3-href');
    is((shift @urls2)->get_attribute('href'), 'http://localhost/foo/bar', 'url4-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234', 'url5-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.opensuse.org/show_bug.cgi?id=2345', 'url6-href');
    is((shift @urls2)->get_attribute('href'), 'https://progress.opensuse.org/issues/3456', 'url7-href');
    like((shift @urls2)->get_attribute('href'), qr{/tests/4567}, 'url8-href');
    like((shift @urls2)->get_attribute('href'), qr{/tests/5678/modules/welcome/steps}, 'url9-href');
    is((shift @urls2)->get_attribute('href'), 'https://progress.opensuse.org/issues/6789', 'url10-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=7890', 'url11-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1000629', 'url12-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1246', 'url14-href');
    is((shift @urls2)->get_attribute('href'), 'https://github.com/os-autoinst/openQA/issues/1234', 'url15-href');
    is((shift @urls2)->get_attribute('href'), 'https://github.com/os-autoinst/os-autoinst/issues/960', 'url16-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.gnome.org/show_bug.cgi?id=768954', 'url17-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.redhat.com/show_bug.cgi?id=1401123', 'url18-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.gnome.org/show_bug.cgi?id=690345', 'url19-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.redhat.com/show_bug.cgi?id=343098', 'url20-href');
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1043970', 'url21-href');
};

subtest 'commenting in test results including labels' => sub {

    # navigate to comments tab of test result page
    $driver->find_element_by_link_text('Job Groups')->click();
    $driver->find_element_by_link_text('Build0048')->click();
    $driver->find_element('.status')->click();
    is(
        $driver->get_title(),
        'openQA: opensuse-Factory-DVD-x86_64-Build0048-doc@64bit test results',
        'on test result page'
    );
    switch_to_comments_tab(0);

    subtest 'help popover' => sub {
        wait_for_ajax(msg => 'comments tab loaded');
        disable_bootstrap_animations;
        my $help_icon = $driver->find_element('#commentForm .help_popover.fa-question-circle');
        $help_icon->click;
        is wait_for_element(selector => '.popover-header')->get_text, 'Help for comments', 'popover shown on click';
        $help_icon->click;
    };

    subtest 'add label' => sub {
        $driver->find_element('#commentForm .help_popover.fa-ticket')->click;
        my $textarea = $driver->find_element_by_id('text');
        like $textarea->get_value, qr/label:force_result:new_result/, 'label template added';
        $driver->find_element_by_id('submitComment')->click;
        throws_ok { wait_for_ajax(msg => 'alert when trying to submit comment') } qr/unexpected alert/,
          'alert already shown shown when trying to wait for it';
        like $driver->get_alert_text, qr/Invalid result 'new_result' for force_result/, 'error from server shown';
        $driver->dismiss_alert;
        $textarea->clear;
    };

    # do the same tests for comments as in the group overview
    test_comment_editing(1);

    write_comment $test_message, 'comment added';

    subtest 'add job status icons' => sub {
        my $urls = <<"EOM";
Can you see status circles after the URLs?

- I'm green! $url/t80000
- I'm red! $url/t99938
EOM
        write_comment $urls, 'comment with job status icons';
        $driver->refresh;
        wait_for_ajax msg => 'comment with status icons loaded';
        my @i = $driver->find_elements('div.comment-body span.openqa-testref i.status');
        is $i[0]->get_attribute('class'), 'status fa fa-circle result_passed', 'Icon for success is shown';
        is $i[1]->get_attribute('class'), 'status fa fa-circle result_failed', 'Icon for failure is shown';
    };

    subtest 'check comment availability sign on test result overview' => sub {
        $driver->find_element_by_link_text('Job Groups')->click();
        like(
            $driver->find_element_by_id('current-build-overview')->get_text(),
            qr/\QBuild 0048\E/,
            'on the right build'
        );
        $driver->find_element('#current-build-overview a')->click();

        $driver->title_is('openQA: Test summary', 'back on test group overview');
        is(
            $driver->find_element('#res_DVD_x86_64_doc .fa-comment')->get_attribute('title'),
            '3 comments available',
            'test results show available comment(s)'
        );
    };

    subtest 'add label and bug and check availability sign' => sub {
        $driver->get('/tests/99938#comments');
        write_comment 'label:true_positive', 'comment added to job 99938';
        $driver->find_element_by_link_text('Job Groups')->click();
        $driver->find_element('#current-build-overview a')->click();
        is(
            $driver->find_element('#res_DVD_x86_64_doc .fa-bookmark')->get_attribute('title'),
            'Label: true_positive',
            'label icon shown'
        );
        $driver->get('/tests/99939#comments');
        write_comment 'label:force_result:passed:forceresult_for_testing_purposes', 'comment added to job 99939';
        $driver->find_element_by_link_text('Job Groups')->click();
        $driver->find_element('#current-build-overview a')->click();
        is(
            $driver->find_element('#res_DVD_x86_64_kde .fa-bookmark')->get_attribute('title'),
            'Label: force_result:passed:forceresult_for_testing_purposes',
            'force_result label icon shown'
        );
        $driver->get('/tests/99938#comments');
        write_comment 'bsc#1234 poo#4321', 'comment added to job 99938 (2)';
        $driver->find_element_by_link_text('Job Groups')->click();
        $driver->find_element('#current-build-overview a')->click();
        is(
            $driver->find_element('#res_DVD_x86_64_doc .fa-bug')->get_attribute('title'),
            "Bug referenced: bsc#1234\nsome title with \"quotes\" and <html>elements</html>",
            'bug icon shown for bsc#1234, title rendered with new-line, HTML code is rendered as text'
        );
        is(
            $driver->find_element('#res_DVD_x86_64_doc .fa-bolt')->get_attribute('title'),
            'Bug referenced: poo#4321',
            'bug icon shown for poo#4321'
        );
        my @labels = $driver->find_elements('#res_DVD_x86_64_doc .test-label', 'css');
        is(scalar @labels, 3, '3 bugrefs shown');
        $t->get_ok($driver->get_current_url())->status_is(200);
        is($t->tx->res->dom->at('#res_DVD_x86_64_doc .fa-bug')->parent->{href},
            'https://bugzilla.suse.com/show_bug.cgi?id=1234');
        $driver->find_element_by_link_text('opensuse')->click();
        is($driver->find_element('.badge-all-passed')->get_attribute('title'),
            'All passed', 'build should be marked because all tests passed');

        subtest 'progress items work, too' => sub {
            $driver->get('/tests/99926#comments');
            write_comment 'poo#9876', 'comment added to job 99926';
            $driver->find_element_by_link_text('Job Groups')->click();
            like(
                $driver->find_element_by_id('current-build-overview')->get_text(),
                qr/\QBuild 87.5011\E/,
                'on the right build'
            );
            $driver->find_element('#current-build-overview a')->click();
            is(
                $driver->find_element('#res_staging_e_x86_64_minimalx .fa-bolt')->get_attribute('title'),
                'Bug referenced: poo#9876',
                'bolt icon shown for progress issues'
            );
        };

        subtest 'latest bugref first' => sub {
            $driver->get('/tests/99926#comments');
            write_comment 'poo#9875 poo#9874', 'comment added to job 99926 (2)';
            $driver->find_element_by_link_text('Job Groups')->click();
            like(
                $driver->find_element_by_id('current-build-overview')->get_text(),
                qr/\QBuild 87.5011\E/,
                'on the right build'
            );
            $driver->find_element('#current-build-overview a')->click();
            my @bugrefs = $driver->find_elements('#res_staging_e_x86_64_minimalx .fa-bolt', 'css');
            is($bugrefs[0]->get_attribute('title'), 'Bug referenced: poo#9876', 'first bugref shown');
            is($bugrefs[1]->get_attribute('title'), 'Bug referenced: poo#9875', 'second bugref shown');
            is($bugrefs[2]->get_attribute('title'), 'Bug referenced: poo#9874', 'third bugref shown');
            is($bugrefs[3], undef, 'correct number of bugrefs shown');
            $t->get_ok($driver->get_current_url())->status_is(200);
            is($t->tx->res->dom->at('#res_staging_e_x86_64_minimalx .fa-bolt')->parent->{href},
                'https://progress.opensuse.org/issues/9876');
        };

        $driver->find_element_by_link_text('opensuse')->click();
    };
};

subtest 'commenting on parent group overview' => sub {
    $driver->get('/parent_group_overview/1');
    test_comment_editing(0);

    # add another comment to have an equal amount of comments in the parent group and in the job group
    # to unify further checks for pagination between the group overview pages
    # (the job group overview has one more so far because of subtest 'URL auto-replace')
    write_comment 'yet another comment', 'comment added to parent group';
};

subtest 'editing when logged in as regular user' => sub {
    my @group_overview_urls = ('/group_overview/1001', '/parent_group_overview/1');

    sub no_edit_no_remove_on_other_comments_expected {
        is(@{$driver->find_elements('button.trigger-edit-button', 'css')},
            0, 'edit not displayed for other users comments');
        is(@{$driver->find_elements('button.remove-edit-button', 'css')}, 0, 'removal not displayed for regular user');
    }

    sub only_edit_for_own_comments_expected {
        is(@{$driver->find_elements('button.trigger-edit-button', 'css')}, 1, 'own comments can be edited');
        is(@{$driver->find_elements('button.remove-edit-button', 'css')}, 0,
            'no comments can be removed, even not own');
    }

    subtest 'test pinned comments: ' . $_ => sub {
        my $group_url = $_;
        $driver->get($group_url);
        write_comment $description_test_message, 'pinned comment added to job group';
        $driver->get($group_url);
        is($driver->find_element('#group_descriptions .media-comment')->get_text(),
            $description_test_message, 'comment is pinned');
      }
      for (@group_overview_urls);

    $driver->get('/login?user=nobody');
    subtest 'test results' => sub {
        $driver->get('/tests/99938#comments');
        wait_for_ajax(msg => 'comments tab for job 99938 loaded');
        no_edit_no_remove_on_other_comments_expected;
        write_comment 'test by nobody', 'comment for job 99938 added by regular user';
        switch_to_comments_tab(6);
        only_edit_for_own_comments_expected;
    };

    subtest 'group overview: ' . $_ => sub {
        my $group_url = $_;
        $driver->get($group_url);
        no_edit_no_remove_on_other_comments_expected;
        write_comment 'test by nobody', 'comment for group added by regular user';
        only_edit_for_own_comments_expected;

        # pinned comments are not shown (pinning is only possible when commentator is operator)
        write_comment $description_test_message, 'comment with pinning for group added by regular user';
        $driver->get($group_url);
        is(scalar @{$driver->find_elements('.pinned-comment-row')}, 1, 'there shouldn\'t appear more pinned comments');

        # verify the number of comments we have added so far for easier debugging in case subsequent tests fail
        my $group_id = (split('/', $group_url))[-1];
        my %cond = (-or => [{group_id => $group_id}, {parent_group_id => $group_id}]);
        is $comments->search(\%cond)->count, 5, 'expected number of comments present in database at this point';

        # pagination present
        is(scalar @{$driver->find_elements('.comments-pagination a')}, 1, 'one pagination button present');
        $driver->get($group_url . '?comments_limit=2');
        my @pagination_buttons = $driver->find_elements('.comments-pagination a', 'css');
        is(scalar @pagination_buttons, 4, 'four pagination buttons present (one is >>)');
        is(scalar @{$driver->find_elements('.comment-row')}, 2, 'only 2 comments present');
        $pagination_buttons[2]->click();
        is(scalar @{$driver->find_elements('.comment-row')}, 1, 'only 1 comment present on last page');
      }
      for (@group_overview_urls);
};

ok(javascript_console_has_no_warnings_or_errors(), 'no unexpected js warnings');

kill_driver();

done_testing();
