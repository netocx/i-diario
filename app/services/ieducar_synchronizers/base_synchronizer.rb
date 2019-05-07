class BaseSynchronizer
  class << self
    def synchronize!(params)
      worker_batch = params[:worker_batch]
      worker_state = WorkerState.find(params[:worker_state_id])
      worker_state.start!

      new(
        params.slice(
          :synchronization,
          :worker_batch,
          :year,
          :unity_api_code,
          :entity_id
        )
      ).synchronize!

      worker_batch.increment
      finish_worker(worker_state, worker_batch, params[:synchronization])
      SynchronizationOrchestrator.new(worker_batch, worker_name, params).enqueue_next
    rescue StandardError => error
      worker_state.mark_with_error!(error.message) if error.message != '502 Bad Gateway'

      raise error
    end

    private

    def finish_worker(worker_state, worker_batch, synchronization)
      worker_state.end!

      synchronization.mark_as_completed! if worker_batch.all_workers_finished?
    end

    def worker_name
      to_s
    end
  end

  def initialize(params)
    self.synchronization = params[:synchronization]
    self.worker_batch = params[:worker_batch]
    self.entity_id = params[:entity_id]
    self.year = params[:year]
    self.unity_api_code = params[:unity_api_code]
    self.filtered_by_unity = params[:filtered_by_unity]

    worker_batch.touch
  end

  protected

  attr_accessor :synchronization, :worker_batch, :worker_state, :entity_id, :year, :unity_api_code,
                :filtered_by_year, :filtered_by_unity

  def api
    @api = api_class.new(synchronization.to_api, synchronization.full_synchronization)
  end

  def api_class
    IeducarApi::Base
  end

  def unity(api_code)
    @unities ||= {}
    @unities[api_code] ||= Unity.find_by(api_code: api_code)
  end

  def teacher(api_code)
    @teachers ||= {}
    @teachers[api_code] ||= Teacher.find_by(api_code: api_code)
  end

  def student(api_code)
    @students ||= {}
    @students[api_code] ||= Student.with_discarded.find_by(api_code: api_code)
  end

  def student_enrollment(api_code)
    @student_enrollments ||= {}
    @student_enrollments[api_code] ||= StudentEnrollment.with_discarded.find_by(api_code: api_code)
  end

  def exam_rule(api_code)
    @exam_rules ||= {}
    @exam_rules[api_code] ||= ExamRule.find_by(api_code: api_code)
  end

  def course(api_code)
    @course ||= {}
    @course[api_code] ||= Course.with_discarded.find_by(api_code: api_code)
  end

  def grade(api_code)
    @grade ||= {}
    @grade[api_code] ||= Grade.with_discarded.find_by(api_code: api_code)
  end

  def classroom(api_code)
    @classrooms ||= {}
    @classrooms[api_code] ||= Classroom.with_discarded.find_by(api_code: api_code)
  end

  def discipline(api_code)
    @disciplines ||= {}
    @disciplines[api_code] ||= Discipline.find_by(api_code: api_code)
  end

  def knowledge_area(knowledge_area_id)
    @knowledge_areas ||= {}
    @knowledge_areas[knowledge_area_id] ||= KnowledgeArea.with_discarded.find_by(api_code: knowledge_area_id)
  end

  def rounding_table(api_code)
    @rounding_tables ||= {}
    @rounding_tables[api_code] ||= RoundingTable.find_by(api_code: api_code)
  end
end
