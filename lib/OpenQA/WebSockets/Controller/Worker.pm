# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebSockets::Controller::Worker;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use DBIx::Class::Timestamps 'now';
use OpenQA::Schema;
use OpenQA::Log qw(log_debug log_error log_info log_warning log_trace);
use OpenQA::Constants qw(WEBSOCKET_API_VERSION MIN_TIMER);
use OpenQA::WebSockets::Model::Status;
use OpenQA::Jobs::Constants;
use DateTime;
use Data::Dump 'pp';
use Feature::Compat::Try;
use Mojo::Util 'dumper';

use constant LOG_WORKER_STATUS_MESSAGES => $ENV{OPENQA_LOG_WORKER_STATUS_MESSAGES} // 0;

sub ws ($self) {
    my $status = $self->status;

    # add worker connection
    my $worker_id = $self->param('workerid');
    return $self->render(text => 'No worker ID', status => 400) unless $worker_id;
    return undef unless defined $status->add_worker_connection($worker_id, $self);

    # upgrade connection to websocket by subscribing to events
    $self->on(json => \&_message);
    $self->on(finish => \&_finish);
    $self->inactivity_timeout(0);    # Do not force connection close due to inactivity
    $self->tx->max_websocket_size(10485760);
}

sub _finish ($self, $code, $reason) {
    return undef unless $self;

    my $worker = OpenQA::WebSockets::Model::Status->singleton->remove_worker_connection($self->tx);
    unless ($worker) {
        log_error('Worker not found for given connection during connection close');
        return undef;
    }
    $reason = ($reason ? ": $reason" : '');
    log_info("Worker $worker->{id} websocket connection closed - $code$reason");
    delete $worker->{last_seen};

    # note: Not marking the worker immediately as offline because it is expected to reconnect if the connection
    #       is lost unexpectedly. It will be considered offline after the configured timeout expires.
}

sub _message ($self, $json) {
    my $app = $self->app;
    my $schema = $app->schema;
    my $tx = $self->tx;

    # find relevant worker
    my $worker_status = OpenQA::WebSockets::Model::Status->singleton->worker_by_transaction->{$tx};
    unless ($worker_status) {
        $app->log->warn('A message received from unknown worker connection');
        log_debug(sprintf('A message received from unknown worker connection (terminating ws): %s', dumper($json)));
        $self->finish('1008', 'Connection terminated from WebSocket server - thought dead');
        return undef;
    }
    my $worker_id = $worker_status->{id};
    my $worker_db = $worker_status->{db};

    # check whether the worker/job had was idle before despite a job assignment and unset that flag
    my $worker_previously_idle = delete $worker_status->{idle_despite_job_assignment};

    unless (ref($json) eq 'HASH') {
        log_error(sprintf('Received unexpected WS message "%s from worker %u', dumper($json), $worker_id));
        $self->finish(1003 => 'Received unexpected data from worker, forcing close');
        return undef;
    }

    # make sure no worker can skip the initial registration
    if (($worker_db->websocket_api_version || 0) != WEBSOCKET_API_VERSION) {
        log_warning("Received a message from an incompatible worker $worker_id");
        $self->send({json => {type => 'incompatible'}});
        $self->finish(
            1008 => 'Connection terminated from WebSocket server - incompatible communication protocol version');
        return undef;
    }

    my $message_type = $json->{type};
    if ($message_type eq 'quit') {
        $worker_db->update({t_seen => undef, error => 'graceful disconnect at ' . DateTime->now(time_zone => 'UTC')});
        $worker_db->reschedule_assigned_jobs;
    }
    elsif ($message_type eq 'rejected') {
        my $job_ids = $json->{job_ids};
        my $reason = $json->{reason} // 'unknown reason';
        return undef unless ref($job_ids) eq 'ARRAY' && @$job_ids;

        my $job_ids_str = join(', ', @$job_ids);
        log_debug("Worker $worker_id rejected job(s) $job_ids_str: $reason");

        # re-schedule rejected job if it is still assigned to that worker
        try {
            $schema->txn_do(
                sub {
                    my @jobs = $schema->resultset('Jobs')
                      ->search({id => {-in => $job_ids}, assigned_worker_id => $worker_id, state => ASSIGNED});
                    $_->reschedule_state for @jobs;
                });
        }
        catch ($e) {
            # uncoverable statement
            log_warning("Unable to re-schedule job(s) $job_ids_str rejected by worker $worker_id: $e");
        }

        # log that we 'saw' the worker
        $worker_db->seen;
    }
    elsif ($message_type eq 'accepted') {
        my $job_id = $json->{jobid};
        return undef unless $job_id;

        # verify whether the job has previously been assigned to the worker and can actually be accepted
        my $job = $worker_db->unfinished_jobs->find($job_id);
        if (!$job) {
            log_info("Worker $worker_id accepted job $job_id which was never assigned to it or has already finished");
            return undef;
        }

        # assume the job setup is done by the worker
        $schema->resultset('Jobs')->search({id => $job_id, state => ASSIGNED, t_finished => undef})
          ->update({state => SETUP});

        # update the worker's current job, log that we 'saw' the worker
        $worker_db->update({job_id => $job_id, t_seen => now()});
        log_debug("Worker $worker_id accepted job $job_id");
    }
    elsif ($message_type eq 'worker_status') {
        my $current_worker_status = $json->{status};
        my $worker_is_broken = $current_worker_status eq 'broken';
        my $current_worker_error = $worker_is_broken ? $json->{reason} : undef;
        my $job_info = $json->{job} // {};
        my $job_status = $job_info->{state};
        my $job_id = $job_info->{id};
        my $job_settings = $job_info->{settings} // {};
        my $job_token = $job_settings->{JOBTOKEN};
        my $pending_job_ids = $json->{pending_job_ids} // {};

        log_trace "Received from worker $worker_id worker_status message: " . dumper($json)
          if LOG_WORKER_STATUS_MESSAGES;

        # detect if the websocket server is running too close to its limit and falling behind with status updates
        # (the status "working" is special because it will be sent immediately after a worker started a new job)
        my ($last_seen, $now) = ($worker_status->{last_seen}, time);
        if ($last_seen && ($last_seen + MIN_TIMER) > $now) {
            log_info("Received worker $worker_id status too close to the last update,"
                  . ' websocket server possibly overloaded or worker misconfigured')
              if $current_worker_status ne 'working';
        }
        $worker_status->{last_seen} = $now;

        my $workers = $schema->resultset('Workers');
        return undef unless my $worker = $workers->find($worker_id);

        # log that we 'saw' the worker
        try {
            log_trace("Updating seen of worker $worker_id from worker_status ($current_worker_status)");
            $worker->seen({error => $current_worker_error});

            # Tell the worker that we saw it (used for tests and debugging)
            $tx->send({json => {type => 'info', seen => 1}});
        }
        catch ($e) {
            log_error("Failed updating seen and error status of worker $worker_id: $e");    # uncoverable statement
        }

        # find the job currently associated with that worker and check whether the worker still
        # executes the job it is supposed to
        my @unfinished_jobs = $worker->unfinished_jobs;
        my $current_job = $worker->job // $unfinished_jobs[0]
          or return undef;
        my $current_job_id = $current_job->id;
        my $current_job_state = $current_job->state;

        log_trace("Found job $current_job_id in DB from worker_status update sent by worker $worker_id");
        log_trace("Received request has job id: $job_id") if defined $job_id;
        my $registered_job_token = $worker->get_property('JOBTOKEN');
        log_trace("Worker $worker_id for job $current_job_id has token $registered_job_token")
          if defined $registered_job_token;
        log_trace("Received request has token: $job_token") if defined $job_token;

        # skip any further actions if worker just does the one job we expected it to do
        return undef
          if ( defined $job_id
            && defined $job_token
            && defined $registered_job_token
            && $job_id eq $current_job_id
            && (my $job_token_correct = $job_token eq $registered_job_token)
            && OpenQA::Jobs::Constants::meta_state($current_job_state) eq OpenQA::Jobs::Constants::EXECUTION)
          && (scalar @unfinished_jobs <= 1);
        try {
            # give worker a second chance to process the job assignment
            # possible situation on the worker: The worker might be sending a status update claiming it is
            # idle (or has doing that task piled up on the event loop). At the same time a job arrives. The
            # message regarding that job will be processed after sending the idle status. So let's give the
            # worker another chance to process the message about its assigned job.
            if ($worker_previously_idle) {
                log_debug("Rescheduling jobs assigned to worker $worker_id");
                $worker->reschedule_assigned_jobs([$current_job, @unfinished_jobs]);
            }
        }
        catch ($e) {
            # uncoverable statement
            log_warning("Unable to verify whether worker $worker_id runs its job(s) as expected: $e");
        }
        # consider the worker idle unless it claims to be broken or work on a job
        $worker_status->{idle_despite_job_assignment} = !$worker_is_broken && !defined $job_id;
    }
    else {
        log_error(sprintf('Received unknown message type "%s" from worker %u', $message_type, $worker_status->{id}));
    }
}

1;
